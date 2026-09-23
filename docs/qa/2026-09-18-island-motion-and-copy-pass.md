# 岛动效 + 全岛文案像素级质检（2026-09-18）

方法：`--preview-capture=<s>` 逐时点抓浮窗位图，PIL 统计「亮字像素」（alpha>128 且均亮度>120）
作为"这一帧有没有文字被画出来"的客观量；再用 `--preview-transitions` 读每段形变的 fps / worst 帧时。
证据图留在本目录 `h*-island-auto.png`（改前）与 `n*-island-auto.png`、`after-*.png`（改后）。

## 1. 形变期间遮罩把字切一半（本次主修）

`PanelState` 在收起时刻意让旧收件箱继续挂载（否则覆盖窗口会变成一块空黑盘），
而遮罩是从 560×256 往 297×32 收的 —— 于是中间 ~200 ms 里，遮罩宽度小于内容宽度，
文字被逐字切掉。实测：hover 后 400 ms / 800 ms 两帧分别有 **5311 / 3335** 个亮字像素，
其中一帧的时间戳只剩「10 分」。

修法不是改遮罩，而是给内容一条独立的时钟：`IslandContentChoreography`
（`Views/HUDRootView.swift`）——
- 收起：内容 110 ms 先淡出，形状随后独立收缩（黑盘仍被填满，但不再有半截字）；
- 展开：形状先开，内容延迟 80 ms 用 `strongEaseOut(0.2)` 在轮廓内部显形；
- 落回紧凑态：立刻出点，不做淡入，否则合上的岛会空 200 ms；
- compact→peek 不换族，所以悬停加宽不会被重播成一次淡入。

实测改后：形变中间帧亮字像素 **0**，落位帧 **5317**（内容完整）。
`IslandContentChoreographyTests` 5 例把这几条钉住。

## 2. 一个事实三套说法

同一个"有 1 条待回复"，三处各说各话：紧凑态 tooltip「待回 · 1」、peek「待回 · 1」、
展开态表头「1 条等你回复」、VoiceOver「收起 · 1 项待处理。移入查看。」。
统一成 `N 条X` 一种句式（`CompactIslandPolicy.glance`），并把「移入查看」从 `spoken` 里删掉：
`spoken` 是按钮的 `accessibilityValue`，按钮标签已经写了动作，对着读屏用户喊"移入"是无效指令。
「收起 ·」是折叠控件的状态词漏进了状态播报，一并去掉。
tooltip 拼接时去掉句末「。」，避免出现「3 条待处理。 · 点击打开收件箱」。

## 3. 表头数字与它标注的列表不一致

`inboxHeaderState` 返回的是"胜出类别的条数"，不是列表长度：3 行（1 条待回 + 2 条 @）
被顶上一句「1 条等你回复」标注。改成计数=整张动作列表，并且把数字只放在列表旁边
（区块标题「待处理 (N)」，与页脚「已处理 (N)」对称），notch 带里只留严重度词 + 圆点。
`InboxViewLogicTests` 补 3 例钉住计数语义。

## 4. 对比度预算没覆盖状态句

`IslandInk` 自己的文档写着 tertiary(≈3.9:1) 只用于装饰、"绝不用在用户必须读的句子"，
但展开态的「需要你处理」区块标题、表头状态句、两条折叠按钮都坐在 tertiary 上。
提到 `meta`，并把 `RelativeTimeVocabularyTests.testIslandSyncStateStaysReadable`
的源码扫描从 4 条字面量扩到 11 条，覆盖这一族。

## 5. 死文案

`CompanionProductCopy.compactStatus` 与 `compactHoverHint` 在 `Sources/` 里已无引用，
只有各自的测试还在断言它们 —— 而「收起 · N 项待处理」正是从这块死代码抄进 `spoken` 的。
删除两处定义与对应断言。

## 已知环境限制（不是本次改动引入）

19:17 之后本机 `CADisplayLink` 不再 tick：`--preview-transitions` 每一段都记到 0 帧，
`--preview-peek` 的展开帧变成空黑药丸。用 `git stash` 把 `Sources/` 全量回退到 HEAD 复跑，
症状完全一致，因此与本次改动无关（推断为屏幕被遮挡/会话状态导致窗口 occlusion）。
动效实测数据取自我还能跑帧的 18:44–19:05 窗口；19:17 之后只做静态像素与源码门禁。
**下一次做动效实测前先确认 `--preview-transitions` 的 fps 列非 0。**（当晚 19:39 恢复，
恢复后重测的数据见文末「第二轮」。）

## 验证

- `swift test` 全绿（含新增 5 + 3 例）
- `swift build -c release` 零警告

---

# 第二轮：定时器派发跳 + 工作台「今天」/「待办」

## 6. 岛的五条定时器路径都多一次派发跳

`PanelState` 里 5 个 `Timer` 回调（悬停展开停留、退出折叠防抖、横幅自动收起、
toast 到期、菜单跟踪兜底）都把 body 包在 `Task { @MainActor … }` 里。定时器本来就
在主 runloop 上触发，这层包装只多一次派发：三条用户能感知的路径（peek→收件箱的
自动展开、鼠标移开后收起、横幅自动消失）都比自己的截止时间晚一个 runloop 轮次落地。
改成 `MainActor.assumeIsolated`（`FloatingPanel`/`AppDelegate` 对 NSTrackingArea
已经是这个约定）。

同一个原因还造成一个更隐蔽的问题：**`--preview-transitions` 的 `hover-out-to-compact`
段一直记到 0 帧**，验收记录里"十段形变"其实只有九段被测到 —— 轮询用的嵌套
`RunLoop.run(mode: .default, …)` 会跑定时器但不排空主队列，所以那条路径的收起发生在
这一段被记录之后。去掉派发跳后这段第一次测到：**120.0 fps / p95 8.34 ms / worst 8.36 ms**。

顺带修掉同一段的两个时序坑（`popoverOpen` 闩锁 + 用 `Timer` 而不是 `asyncAfter` 排程），
并补了 `retarget-midflight` 一段：真实的悬停会在 peek 弹簧（~323 ms）飞行中途
（停留 180 ms）就改向成展开，此前没有任何一段在测这种"中途改向"。现在 11 段全部有帧，
除刻意空跑的 `settle-compact` 外，p95 一律 8.35 ms（120 Hz 预算内），worst 8.35–16.67 ms。

## 7. 「今天」页：同一段话印两遍

`AssistantTodayView` 的卡片正文（16 pt）取的是 `aiSummary ?? preview`，而展开后的
「AI 解读」块又把**同一个 `aiSummary`** 原样印了一遍（13 pt）——fixture 里 AI 摘要
等于原话，于是屏幕上是一字不差的两句。再往下还并排着两个"看原文"入口：块里的
`查看原文` 按钮和 `消息原文` 折叠组。

改成：去掉重复正文，把这一条压成紧贴正文的元信息行 `● AI 解读 · 查看消息原文`
（点开的原文就在它下面）。原来那块青色底带在只剩两个词之后变成一条空的色块，
所以连底色一起去掉。卡片高度少约 55 pt。

## 8. 其余确定项

- **同步状态一屏三次**：页脚 `微信已连接 · 刚刚同步` 与同一行右侧 `上次同步 2026年9月18日 19:50`
  是同一件事的两种格式。页脚左侧只留连接状态，新鲜度交给右侧那一列。
- **筛选标签长短不齐**：`需要回复 / 没回的 / 我要做 / 等对方` 是 4/3/3/3，第一颗明显更宽。
  统一成三字：`要回复`。
- **按钮把动作说成状态**：今天页卡片右下角的 `已处理` 是个按钮，收件箱行里同一动作叫
  `标为已处理`。对齐成后者。
- **承诺「全部」筛选的空态描述错了集合**：`没有正在跟进的承诺` —— 全部里含已完成和已取消。
  改为 `还没有记下的承诺`，并加一条断言要求四个筛选标签的空态标题两两不同。
- 待办页保留了两处常驻解释文字（严格度说明、"当前只显示还没做完的…"）。它们各自带着
  前一轮写下的理由（后者是为了从 tertiary 提到 secondary 的可读性决定），本轮不动。

## 第二轮验证

- `swift test` 全绿；`swift build -c release` 零警告
- 岛动效 11 段实测见上；「今天」页改前/改后截图：`today-vs-tasks.png`、`today-card-after.png`


---

# 第三轮：承诺页 / 待办页

## 9. 一个状态三个词

同一个"截止日已经过了"，全仓三种写法：岛和承诺页写 `已到期`，待办页分组写 `已过期`，
日报/设置/回顾写 `已超期`。切一次标签页就能同时看到两种。统一成 `已到期`：

- `SyncSettingsView`（两处）、`DiscussionPresentation.groupTitle`、`InsightAttentionBar`、
  `InsightKPIGrid`、`DailyReportBuilder` 的风险描述与叙述事实行、`DailyReportPresentationPolicy`
  的 markdown 导出、`daily_report_v1.txt` 与内联兜底 prompt（AI 写出来的词也得和界面一致）。
- `DailyReportCommandCenterView.deadlineText` 原来是 `已超期 3分` / `3分后` 两套形状，
  改成 `3分前到期` / `3分后`，过去式和将来式共用同一个相对时间形状。
- 保留的 `过期` 只剩一处：`CodexAuth` 的"Codex 登录态已过期"，那是令牌到期，不是承诺到期。
- 待办页另一类 `过期`（"过期太久自动收起"）说的是"很久没处理"，和截止日无关，
  改成 `很久没处理`（含 `ChatMonitor` 的收起通知），避免和 `已到期` 撞词。
- 加门禁：`RelativeTimeVocabularyTests.testPassedDeadlineIsCalledOneThingAcrossTheApp`
  扫 `Sources/` 全部 `.swift`/`.txt`，除 CodexAuth 外不允许出现 `超期`/`过期`。

## 10. 承诺页：页头三行说同一件事

`我答应的事` / 副标题 `已答应的事` / 正文 `这里只记你明确答应过的事 — 不受…`，
三行两行是同义反复。副标题删掉，并把 `Tab.subtitle` 改成可选（`Text` 随之条件渲染），
因为规则本身应该是"这一行要么带信息，要么不占高度"，而不是"每页必须有一句"。
正文那句去掉破折号、补上因果：`这里只记你明确答应过的事，所以不受「待办」页保留档位的影响。`

顺带两处视觉：

- 逾期行的截止时间原来是 `.secondary`，和正常行一模一样，划出分组标题后就没有任何
  线索说这条晚了 → 逾期且未完成时改橙色；展开卡片的描边原来一律青色（ jade 读作"完成"），
  逾期时改琥珀色。
- `已到期 1` 药丸在计数 >0 时转琥珀色（上一轮删掉重复控件后，它是这一页唯一的告警位）。

## 11. 待办页：两行筛选器共用一套词

上排 `保留 [全部都记 | 只留要做的 | 只留压在我身上的]`，下排归属药丸
`[全部 | 我要做 | 等对方 | 共同推进 | 信息备忘]`。`全部都记` vs `全部`、
`只留要做的` vs `我要做` —— 两个维度用同一批词，读起来像下排是上排的展开。

上排说的是"助手记多少"，所以三个档位统一带 `记`：`全记 / 只记要做的 / 只记要紧的`。
这同时修掉一处文案与算法不符：`只留压在我身上的` 声称只留用户自己的事，
而 `admits(.pressing)` 里 `owner == .mine || owner == .theirs` 都放行（等对方的也算），
`只记要紧的` 不再做这个断言，精确规则交给它下面那行 explanation。

`全部都记` 的两处引用（空态、AX hint）同步改；门禁在
`DiscussionStrictnessTests.testLabelsAndReceiptWordingAreStable`：每个档位标签必须含 `记`，
且不得与任何归属药丸同名。

## 12. 待办详情：同一动作两个入口 + ScrollView 里的 Spacer

标题右上角一个 `⋯` 菜单，里面是 `更正归属` / `查看原文`；下面又摆着同样两个动作的
明面按钮。删掉菜单，留明面的（带图标、不需要先点开）。

`标记完成` 原来和次级动作之间夹了一个 `Spacer(minLength: 12)`：在 `ScrollView` 的
`VStack` 里 Spacer 会撑满视口，于是"完成这条"的按钮落在正文下方约 200 pt 处。
合成一行：左边 `更正归属 · 查看原文`，右边 `标记完成`。

改后截图 `t-tasks-workspace-auto.png`；承诺页 `r-cmt-workspace-auto.png`。

## 第三轮验证

- `swift build` 无警告；`swift test --filter 'Discussion|Product|Workspace|Companion|Settings'` 全绿
  （含新增的两条门禁）

## 13. 草稿页：又一个 `⋯` 重复控件 + 把删除放在中间

- 标题右上角的 `⋯` 菜单里只有 `删除草稿`，而下面动作行里已经摆着同一个 `删除草稿`。
  删菜单，留明面那颗。
- 动作行原来顺序是 `复制 · 删除草稿 · 查看对话 · 继续回复`：不可撤销的动作夹在两个
  安全动作中间，视觉重量和"复制"一样。改成 `复制 · 查看对话 · 继续回复 · 删除草稿`，
  破坏性动作退到行尾。
- 正文输入框常年描一圈青色：`editorFocused` 早就存在，但那圈颜色不看它。改成只在聚焦时
  上青色，平时用 `CompanionPalette.border`——否则"能亮"的那个状态永远不会亮。
- 页头副标题 `确认后发送` 与 `待确认回复` 页一字不差，但这页不发东西（`继续回复` 只是把
  文本交给微信，空态也明说"草稿不会自动发送"）。改成 `改好再去微信发`，并加门禁：
  17 个页面的副标题不得两两相同。

## 14. 聊天回顾：一个词指两样东西，一个动作两个入口

概览页上「AI 解读」出现了两次，指的是两个不同字段：上面那张卡是
`suggestion`（具体行动建议），下面那张是 `insight`（这一天的观察）。用户读到第二个
只会以为是重复。上面的改成 `行动建议`（prompt 里这个字段就叫"具体行动建议"）。

`insight` 原来排在活跃度柱状图和两个待办列表之后 —— 一整页里唯一解释"今天发生了什么"
的那段话，放在最需要往下滚的位置。移到标题卡正下方。

待办列表也有两个：`当前待办`（待办页的权威列表）和 `AI 读到的待办`（模型抽取，下面
还跟一句"不是待办页的权威列表"来拆掉自己标题的误导）。后者改名 `AI 读到的候选`。

`查看待办` / `查看原文` 在页头各出现一次，正文里又各出现一次。删页头那对：
`查看待办` 留在待办卡片上（就在它指的东西旁边），`查看原文` 留在 AI 解读卡里；
只有 `对话时间线` 页保留页头的 `查看原文`，因为那一页正文没有别的入口，
而它的空态文案正在叫用户"或直接查看原文"。

顺带：`还没有 AI 解读时，先看来源和待办。` 的「时」是语病，去掉。

## 15. 全应用：主按钮的青色填充根本没画出来

`ChatInsightDetailView` 的 `重新分析` 是实色青，而 `标记完成`、`继续回复` 和另外
20 个 `.buttonStyle(.borderedProminent)` 画成和 `复制` 一模一样的灰胶囊 —— 一个页面
的主动作和次动作在像素层面无法区分。

对照实验（同一页、同一窗口、同一截图参数，只改一处）：

| 写法 | 填充 |
| --- | --- |
| `.buttonStyle(.borderedProminent)` 然后 `.tint(accent)` | 灰 #303030 |
| `.tint(accent)` 然后 `.buttonStyle(.borderedProminent)` | 实色 #95D2BE |

`.controlSize(.large)` / `.regular` / `.small` 都遵循这个结果，尺寸不是变量。
`.tint()` 必须写在 `.buttonStyle(.borderedProminent)` **之前**。

第一轮排查时我把它写成"无头截图的假象"，那是错的：`--preview-activate` 前后逐像素相同，
而同一次截图里 `重新分析` 是青的 —— 说明截图能画出填充，灰的是代码顺序。

修了全仓 33 处 `.buttonStyle(.borderedProminent)`（21 个文件）的 tint 顺序，并把没有
tint 的（跟随系统强调色，可能是蓝的）统一 `.tint(CompanionPalette.accent)`。门禁
`PrimaryActionStyleTests`：每个 `.buttonStyle(.borderedProminent)` 的上一行必须是
`.tint(`，同一行里写在 style 之后的也不算。

## 第四轮验证

- `swift build` 无警告；`swift test` 全量通过（exit 0）
- 改后截图：`y-insight-workspace-auto.png`、`final-drafts-workspace-auto.png`、
  `final-tasks-workspace-auto.png`；动作行放大图 `final-drafts-actions.png`

## 16. 待确认回复：空态在解释一个看不见的按钮

空态第三句 `暂停不会删除现有草稿。` 说的是 `暂停` 按钮，而那个按钮只在整理运行中出现；
没开始时这一页根本没有它。改成按 `autopilotActive` 分两句：没开始只说"点开始整理后…"，
运行中才补"暂停不会删除现有草稿"。

另发现一个整页重复：`AutopilotTabView.swift`（875 行）没有任何地方实例化，
`ApprovalWorkspaceView` 才是工作台和岛详情用的那份。两份各写了一句同义但不同字的空态
（`点开始后，助理会整理该回的消息` vs `点开始整理后，助理会写成草稿`），这就是文案漂移的
来源。本轮未删（只有一个源码扫描测试还引用它），建议单独一次删除 + 同步那个测试。

---

# 第五轮：今日小结 / 关系雷达

## 17. 今日小结：账号 id 印在名字的位置上

每行元信息里的来源显示的是 `preview-colleague`、`preview-project` —— 微信账号标识，
不是对话名，而且同一行左边就是完整的人名。`resolvedChatName` 无条件相信
`monitor.displayName(for:)`，可解析结果本身可能就是那个 id（`ChatMonitor+ChatNaming`
只在 `wxid_`/群聊形态上判定"这是裸 id"，预览用的 `preview-colleague` 不在其中）。
于是"解析"把已经正确的缓存名覆盖成了 id。

改成：解析结果如果为空、等于被查的 id、或是已知的占位名，就不算名字，保留缓存名。
风险行（原来直接印 `risk.sourceChatName`，不做任何解析）也走同一个函数。
实测改后：`林晓 · 产品同事`、`项目协作群`。

## 18. 今日小结：标题与内容不符 + 内部词

- 区块标题 `紧急待处理`，里面却有一条 `高` 优先级 —— `urgentActions` 取的是
  `critical || high`。标题改 `优先处理`（markdown 导出同步，顺手去掉导出里那个 🔴）。
- `规则整理` 是内部实现词（rule-based vs AI），下面那句"今天本地统计显示…"已经自报
  来源。四处（页面标签、markdown 导出、两条兜底叙述）统一成 `本地统计`。
- 导出里写 `AI 总结`、页面写 `AI 小结`，而这一页本身叫「今日小结」。统一 `AI 小结`。
- 每行两个同形状色块（`标记完成` / `查看待办`），整节 4 行就是 8 个一样的按钮，
  行内没有主次。`查看待办` 降成安静的文字链（图标 + 「待办」，secondary 墨色），
  保留 help 与 AX 标签。

## 19. 关系雷达：空态在重复本页工具栏已经说过的话

工具栏右上角写着 `本机计算 · 不自动发消息`，空态描述里又来一句 `雷达也不会自动发消息`。
同一屏两遍，而且空态那一行本来该用来告诉用户下一步做什么。删掉后半句。

## 第五轮验证

- `swift build` 无警告；`swift test --filter 'DailyReport|Radar|Insight|Analytics|Product|Workspace'` 全绿
- 改前截图：`x-dailyReport-workspace-auto.png`（来源列印着 `preview-colleague`）；
  改后：`z-daily-rows.png`（同一位置已是 `林晓 · 产品同事`）、`zz-daily-rows.png`（动作行降噪后）
- 至此 8 个工作台页全部过完像素；剩 9 个设置分区与岛动效的进一步打磨

---

# 第六轮：9 个设置分区

截图脚本 `/tmp/wcsnap.sh r6-<tab> 3.0 --preview-dark --preview-tab=<tab>`，
产物 `docs/qa/2026-09-18-island-pixel/r6-<tab>-workspace-auto.png`。
读图用 PIL 裁右栏（x 500→2500）再缩到 52%，避免整张 2500×1868 糊在一起。

## 20. 提醒方式：「群里 @ 我的消息」这个开关是假的

`ScanEngine` 里：

```swift
let worthInterrupting = isAt || isCrossGroupVIP || isWatchedMember
let shouldPresent = notificationConfig.shouldPresent(notif.presentationSemanticState)
    || (worthInterrupting && notificationConfig.important)
```

`shouldPresent(.groupMentionFYI)` 已经由 `atMention` 决定，但第二行又把 `isAt`
塞进 `worthInterrupting`：只要「重点关注的人」开着，关掉「群里 @ 我的消息」
什么都不会发生。上面那段注释自己写着「even without an @」，代码却把 @ 算进去了。

改成 `isCrossGroupVIP || isWatchedMember`。每个开关只 owns 自己那一路信号。

行为测试 `ScanClassificationDeliveryTests.testAtMentionSwitchStandsAloneWhenImportantIsOn`：
`atMention=false, important=true` 的群 @ 不再弹，但仍留在收件箱。
先证伪再修——把 `isAt` 加回去，这条测试如期失败（横幅仍在），确认不是空跑。

## 21. 提醒方式：一句话只有一种模式下成立

原文案「关注的群不会因此弹出每一条闲聊」。查 `AdmissionPolicy.decide`：
`whitelistOnly` 模式下群闲聊确实 `.suppress(.notFollowed)`，但 `全部未读都提醒`
模式下走 `.admit(.everyChat)`，这个开关就会弹出每一条。
「已经进入收件箱」本身已经是准确边界，后半句删掉。

同时：
- 「重点关注的人」原来说「私聊会弹出」，实际还管着群里的重点成员 → 补全。
- 页头副标题「谁弹出、停多久」和两个分区标题说同一件事 → 换成真正有信息的
  「只管顶部浮窗」，并把原来脚注里那句边界上移，脚注只留 macOS 通知那条。
- 「展示时间」是「停多久」，不该待在「谁来的消息要弹出」标题下 → 拆成两个分区。

## 22. 自动回复：分区标题重复印页头，只读行长得像坏掉的控制

- `SettingsSection("自动回复")` 在页头「自动回复」正下方 → 改「发到什么程度」。
- 「本次整理最多 50 条」是一行没有控件的只读值，混在一排可操作的行里像渲染坏了
  → 挪进「高级设置」，并说明它是防跑飞的固定护栏。
- 「高级」分区的第一条把 `groupRule` 逐字又印了一遍，而这句话正是上面那个开关
  打开时的副标题 → 删；`occurrences(groupRule)` 从 2 收到 1，测试同步改成断言一次。
- 「不自动回复的人」披露组和它内部的分区标题是同一句话 → 计数上到披露组标签，
  内部分区改无标题。
- 「每小时最多」副标题「每小时发送上限。」只是把标题重说一遍，而且没说是
  全局还是单对话（代码里 `globalSendTimestamps` 是全局的）→ 换成有信息的一句。
- `confidenceTitle/confidenceHint/perHourTitle/perHourHint` 之前是死常量，
  页面用字面量各写一份 → 让页面引用常量，一处改处处改。

## 23. AI 服务：一个状态三套词

同一屏上：卡片徽章「未配置」、供应商状态徽章「已启用 · 未验证」、
底部保存条「配置已保存 · 尚未测试」。
- `ProviderCard` 不再自己造词，改收父视图同一个 `status` 三元组，「已启用」
  整个去掉（这一页没有任何启用/停用开关）。
- 底部改成「配置已保存 · 未验证」。
- 「打开后，相关聊天会发给这个服务」里的「打开」指的不是本页的开关 → 删。
- 「用哪家 AI」分区标题 = 页头副标题「摘要用哪家」= 卡片「当前 AI 服务」=
  行标签「服务来源」，一屏四遍 → 分区改无标题。
- 「分析与建议」分区标题 = 页头「AI 分析与建议」→ 改「让 AI 做什么」；
  「更多帮助」→「额外提示」。
- 「消息摘要 / 显示消息摘要。」是同义反复 → 换成它真正出现的位置。
- 「关键决定面都留着原文入口」是个病句（决定面）→ 「每个关键决定都留着原文入口」。

## 24. 关注谁：一个数字没有含义，一个事实两个词

- 列表行「120m」：英文单位，且没说 120 分钟是「等什么」。详情栏同一个值写的是
  「120 分钟后提醒」→ 行内改「120分」并补 help/a11y 说明。
- 「整理范围 / 只整理已关注的对话」：这句复述的是全局 `AdmissionMode`，
  而用户在同一页就能把它改成「全部未读都提醒」——这句话会自己变谎；
  且「整理范围」根本没描述下面的 类型/提醒时机 → 标题改「这个对话」，删那句。
- 「类型」在「账号信息」里叫「联系人」、在下面又叫「私聊」→ 统一 私聊/群聊，
  并且只在「这个对话」出现一次。
- 「点右上角后会在后台整理」：那个按钮在这一节的右边，不是右上角 → 直接点名按钮。

## 25. 微信连接：一句永远为真的成功回执

`MacExperienceSettingsView` 底部硬写着「✓ 更改已保存」。这一页没有任何写操作
（只读 macOS 状态 + 跳系统设置），也没有 `saved` 状态位——它是一句假回执。删掉。
`AISettingsView` 里同样的字样是 `savedAt != nil` 驱动的，保留。

另外「关闭这个窗口后，助手仍留在顶部和菜单栏。」夹在两行权限中间、两边都有分隔线，
读起来像一项权限 → 移到卡片末尾。

`WeChatConnectionSetupView`：「更换账号前先看清范围：新账号只读自己的聊天。已整理的
待办、草稿和关注名单按账号分开…」这段常驻小字，和「更换微信账号？」确认弹窗里的
那句话逐字重复 → 常驻的那条删掉，挂成按钮的 `.help()`。

## 26. 本地资料：所有未来的截止时间都显示「截止 刚刚」

```swift
Text(d < Date() ? "已到期" : "截止 \(MessageInfo.formatRelative(Int(d.timeIntervalSince1970)))")
```

`formatRelative` 是「过去专用」：`diff = now - ts`，`diff < 60` 就返回「刚刚」。
未来时间戳的 diff 是负数，永远 < 60 → 明天、下周的截止全部渲染成「截止 刚刚」。
改用承诺页已有的 `CommitmentPresentation.timeLabel`（今天给「截止 14:30」，
跨天给「截止 9月19日 14:30」）。

顺带确认：全仓 `formatRelative` 其余 5 个调用点传的都是 `createTime/createdAt`，
只有这一处在拿它算未来。

这一行的 完成/取消 双胶囊看着扎眼，但代码注释写明「取消」上一轮刚从灰色小字
升级成有尺寸的目标（防误删用户自己的承诺），这次不动。

## 第六轮验证

`swift build` 零警告；`swift test --filter 'DeadlineCaptionTests|SyncConnectionDiagnosis|
AutopilotCopyConsistency|Commitment|NotificationPreferences|ScanClassification|
Settings|Accessibility|Workspace'` 全绿。

复拍 `r6-<tab>-workspace-auto.png` 逐页核对：
- 提醒方式：两个分区成立，脚注不再和页头副标题抢同一句话（`r7-notifications`）。
- 自动回复：页头下第一行是「发到什么程度」，只读行已不在主卡里，
  披露组标签带上了计数。
- AI 服务：卡片徽章与供应商状态徽章现在同为「未配置」，底部为「配置已保存 · 未验证」。
- 使用偏好：那行假的「✓ 更改已保存」不再出现，窗口说明落到卡片末尾。
- 本地资料：演示数据里那条未来截止从「截止 刚刚」变成「截止 23:06」——
  这一条是像素上直接看得见的算法修复。

一个仍未定性的现象：无头截图里第一个文本框（这页是「访问凭据」）会带上蓝色聚焦环，
之前侧栏也出现过类似的假焦点环。两次都出现在页面首个可聚焦控件上，
怀疑是 `--preview-activate` 之外的默认 first responder 行为，不是产品缺陷；
没有证据前不改代码。

## 27. 怎么用：入门页也在承诺一个不存在的草稿

「发送和自动回复 / …群聊只记草稿。」——群聊只有在「群里 @我 时也准备回复」打开时
才会写草稿，默认关着的时候只记录、不写回复。改成「群聊不会自动发出」，
这是两种状态下都为真的那一半。
`AutopilotCopyConsistencyTests.testGuideStatesTheGroupGuaranteeRatherThanADraft`
把这条钉住；它顺手抓到了一次失败——我新写的代码注释里正好引用了那句被禁的原文。

---

# 第七轮：岛动画的逐帧实测（目标点名的那一项）

工具是现成的：`WCHUD_ANIMATION_DEBUG=fast` 打真实速度的逐帧轨迹，
`--preview --preview-hover` 免鼠标触发悬停展开。
`/tmp/trace1.txt` = 改前，`/tmp/trace3.txt` = 改后。

## 28. 掉帧时岛会贴着刘海抖 2 秒 —— 本轮最大的缺陷

改前的真实轨迹（60 Hz）本身没问题：展开 400ms、收起 450ms、边缘不来回跳。
把同一个积分器按不同帧率离线跑（`IslandSpringCadenceTests` 就是这套测量），
结果是：

| 帧率 | 收起耗时 | 画出来的边越过目标的次数 |
|---|---|---|
| 120 Hz | 408ms | 0 |
| 60 Hz | 450ms | 0 |
| 30 Hz | **2367ms** | **53** |
| 24 Hz | 3042ms（撞 2.5s 楔子帽才停） | 73 |
| 20 Hz | 3050ms（同上） | 61 |

根因：`IslandFrameSpring.step` 一个 vsync 只做一次半隐式欧拉步。
收起用的 stiffness 下 ω≈31 rad/s，33ms 的步长让 `ω·h≈1.0`，
单步能量误差足以把 *量化后* 的矩形推到目标另一侧——于是岛在刘海下面
左右各 3pt 地来回抖 1.9 秒，最后才被楔子帽硬拉停。
`IslandMotion.maxStep`（1/20s）是「卡死钳」不是「子步钳」，30Hz 的 33ms 直接穿过它。

修法是标准的定长子步：`IslandMotion.subStep = 1/120`，`step(dt:)` 拆成 N 个
`integrate(dt:)`。实测 1/120 是甜点（1/240 在低帧率反而开始重新出现单次翻转，
60Hz 下又没有任何收益）。修完：

| 帧率 | 收起耗时 | 翻转 |
|---|---|---|
| 30 Hz | 333ms | 0 |
| 24 Hz | 333ms | 0 |
| 20 Hz | 350ms | 0 |

而且 20→120Hz 的曲线形状现在一致了——同一套弹簧常数在任何屏幕上都是同一个动作。

## 29. 那个「弹出来」原来是积分误差，不是设计

子步一上，展开的过冲从 +9.4pt 掉到 +0.2pt：说明旧的 ζ=0.82 根本没在弹，
是粗步长漏进去的能量在冒充弹跳。文档注释写着「expand is slightly underdamped
so the island visibly pops out」，实际画出来的是临界阻尼贴边。

所以这次是真的把弹跳做成参数，而不是留着当巧合：pop 段改 response 0.34 / ζ=0.62，
离网模拟给 +9pt 高 / +10pt 宽，真机轨迹给 +14.5pt（叠上 retarget 继承的速度），
恰好一次方向反转（弹出去再落回来，不是 ringing）。代价 33ms。

## 30. 收起比展开还慢，而且标称值在说谎

`expandDuration=0.36 / collapseDuration=0.22` 是标签，实测 400ms / 450ms——
收起比它要跟随的展开还慢 50ms，正好和设计意图相反。
收起/入场段的 response 0.26 → 0.20：真机收起 450 → **319ms**，展开 350ms，
快慢关系恢复正常；两个标称值改成实测的 0.38 / 0.33。

## 31. 顺带：被测试当成产品事实的两个旧断言

- `testSettlesWhenEveryPaintedFrameIsQuantized` 直接把弹簧瞄到目标矩形，
  而生产路径瞄的是量化格中心（`FloatingPanel.springTarget`）。「存下来的矩形 ==
  目标矩形」只对后者成立；收紧 response 后残差换了一侧，断言就崩了。
  改成按生产的方式瞄，测的才是真正成立的不变量。
- `testHoverExpansionLandsOnTheStoredRectWithoutRinging` 要求尾部宽度**严格单调**。
  一个真正的弹跳必然有一次回落，于是它把设计判成了 bug。改成「最多一次方向反转」，
  ringing（反复越像素边界）仍然拦得住。

## 第七轮验证

`swift test` 全量退出码 0；`swift build -c release` 零警告；
`swift test --filter 'Island|Motion|Panel|Notch|Compact'` 212 条全绿。
真机 `WCHUD_ANIMATION_DEBUG=fast --preview --preview-hover` 改后轨迹：

```
peek 加宽        175ms  h 32->32   峰值 32.0   反转 0
展开到收件箱      350ms  h 37->256  峰值 270.5  反转 1   ← +14.5pt 的弹
收起回胶囊        319ms  h 219->32  峰值 219.0  反转 0
```

改前同一动作：展开 400ms、收起 450ms；30Hz 下收起 2367ms 且抖 53 次。

---

# 第八轮：Services 算法与界面承诺一致性

前七轮在岛上和设置页。这一轮进 Services：界面上每一句承诺，去追它对应的算法，
看那个数字/那个词到底是谁算出来的。

## 32. 「超时」这一个词，曾经有三把不同的尺子

`ReplyDebtScorer` 用配置档位算 `age >= window` 并写下 `.overdue` 理由；
`InboxBuilder` 却拿 `predictReplyWindow`（VIP 10/20、白名单私聊 15/60、默认 30/120
的**建议回复时长**）当阈值，还用了 `>` 而不是 `>=`；
`InboxContextBuilder` 又独立第三种写法。结果同一条消息，收件箱行的徽章和它自己
的理由列表可以互相打脸，详情面板的「超时N分」从另一把尺子上量出来。

收口成一个函数 `ReplyDebtConfig.overdueWindow(contactWindowMinutes:isGroup:isAtMention:isVIP:config:)`，
三处全部改为调用它；`ReplyDebtItem` 新增 `overdueThresholdMinutes`，把自己用的那把尺子
**公布出去**，而不是留给下游各自再猜一遍——猜的地方越多，分叉越多。
`predictReplyWindow` 连同它 7 个分支一起删除：它没有任何界面读取，唯一的用途就是把
错误数字送进徽章。

## 33. `replyWindowMinutes == 0` 是「没设」，不是「立刻超时」

11 个角色里 3 个（点头之交 / 仅群聊 / 服务号）默认写 0。评分器把 0 读成「未设置」并回退到
档位；`InboxContextBuilder` 把它当成字面阈值，于是 `age >= 0` 恒成立——一个点头之交的会话
永远挂着「超时」徽章，徽章上的数字就是消息已经躺了多久。

设置页那句「设为 0 不追踪」同样是假的（0 从来不关闭任何东西），控件标题
「提醒时机」也名不副实（这个数不安排任何提醒，只决定多久算超时、从而抬高排序）。
三处文案改成「多久算超时」+「超过这个时长还没回，这条就标成超时、排得更靠前。0 = 用默认时长。」

## 34. 主动提醒的四条规则，两条在说谎

- 规则 3 标题「连续消息」：统计的其实是该发信人**所有**未回的可提醒条目，跨会话、
  不做相邻判断，三条上周的旧消息也算「连续」。改成「多条未回 / X 有 N 条消息还没回」。
- 规则 4 读 `.first` 再判断是不是 P0。列表按优先级排序，所以 `.first` 确实是最高优先那条——
  但它一旦正好是你正在输入的会话，整条规则就哑了，后面排着的 P0 永远不响。
  改为 `first(where: { $0.priority == .p0 && !activeConversations.contains(...) })`，
  仍然每次评估最多推一条（这条路径不吃预算，不能放大成扇出）。
- `.t4` 文案「VIP 等你超过 4 小时」：档位恰好在 240 分钟触发，「超过」差了边界；
  与 2 小时档统一成「VIP 等你 4 小时了」。
- `VIPAlertTier.compute(overdueMinutes:)` 的参数名和文档都在说「超时」，实际传进去的是
  消息年龄。改名 `waitingMinutes`，并在文档里写明这四档是**固定的等待里程碑**，
  不跟随「多久算超时」设置——否则用户调那个设置，会以为提醒档位也跟着动。

## 35. 单对话分析不可能知道的事，就别让它填

`chat_insight_v3.txt` 要求模型输出 `cross_chats`（「也在讨论的群」），而
`AIChatInsight.buildPrompt` 只拿得到：这一个会话的消息、这一个会话的记忆、
以及由该会话自身 keyTopics/pendingItems 拼出的 recentContext。别的会话名字**从来不会**
进入这次调用。所以这个字段要么编、要么从别处串进来。删字段、删「也在：某群」chip。
解码仍兼容（旧存量里带这个字段），只是不再渲染。

## 36. 全局简报算了却没人看的那一半

`cross_topics` 是全局简报独有的能力——它一次看到所有会话，所以「同一个话题在三个对话里
说法不一致」只有它能说。prompt 要了，模型给了，`GlobalBriefing.crossTopics` 解码了，
然后**没有任何界面渲染它**。而洞察页头部那句文案早就写着
「列出该做的事和跨对话话题」：产品付了 token，界面却违背了自己的承诺。

接进洞察雷达（新增 `Kind.crossTopic`）：有 `conflict` 时算 high、标题
「「X」在这几个对话里说法不一致」、依据行直接给冲突原文；没有冲突时 medium、
「「X」在 N 个对话里都在讨论」。计数只数**叫得出名字**的会话（「全局/未知/空」是模型的填充值，
计入会虚报 N），不足两个就不出这一行；超过 3 个在理由里补「等」，不静默截断。
不提供「打开对话」按钮——一条跨会话的结论跳进其中一个会话，本身就是误导。

## 37. AGENTS.md / README 里的幽灵功能

- **Smart Digest**：AGENTS.md 写了「离开 30 分钟后返回自动提示你错过了什么」。
  全仓 0 处实现。删条目。
- 「主动提醒：VIP超时/连续消息/P0待回」与 README 同一句话，按第八轮改后的真实措辞更新；
  README 面向客户的说法直接用界面词。
- 「跨对话关联：检测多个对话中的共同关键词」现在才真的有实现。

## 38. 新增行为测试与证伪

`OverdueWindowConsistencyTests` 8 条 + `CrossTopicRadarTests` 8 条 +
`ProactiveAlertTests` 2 条（P0 被活跃会话挡住时仍要响；一次评估最多一条）。

证伪记录（先证伪再修）：
- 把 `InboxBuilder` 的阈值改回当年那个建议值（30）→ 90/119/120/121/240 分钟五档里
  4 档立刻失败，徽章与理由重新打架。
- 把 `contactWindowMinutes > 0` 改成 `>= 0` → 8 条里 6 条失败，包括那条
  「点头之交不该永久超时」。
- 把规则 4 的 `first(where:)` 改回 `.first` → `testP0BehindAnActiveConversationStillAlerts`
  三条断言全红。

第一次写的边界用例（29/30/31 分钟，默认档 120）跑过了旧代码，原因是**选的年龄压根没跨过
那条尺子的边界**——用例太弱而不是代码没错；改成 119/120/121 并补 90 之后才真正咬住。

## 39. 「每次表达 2-3 条连发」是一个没人量过的数

`analyzeTypingRhythm` 已经逐组算出了连发长度（`currentBurstSize`），却在收尾时把长度丢掉，
只留组数比例；`TypingRhythm.multiMessage` 的文案对所有人生成同一句「2-3 条」。
一条 9 条一组的人，AI 收到的是「你习惯发 2-3 条」。
改成 `multiMessage(burstSize:)` 携带实测中位数，文案随人而变。

## 40. 撤回一条：StyleProfiler 的冷启动没有骗人

上一轮审计记了一条「样本 < 20 时返回模板 profile，而界面说『根据你的聊天风格』」。
这轮去追实现：冷启动返回的模板 `fewShotExamples` 为空 → `isEmpty == true` →
`buildStyleHint` / `buildRichStyleHint` 双双 `guard !style.isEmpty` 直接返回 nil，
模板从不以「用户风格」的名义进 prompt。该条撤回。（模板自己标着「（暂无数据）」。）

## 第八轮验证

`swift test` 全量退出码 0（1793 条 XCTest + 70 条 swift-testing，15 条显式 skip）；
`swift build -c release` 零警告。
新增 `OverdueWindowConsistencyTests`(8) / `CrossTopicRadarTests`(8) /
`ProactiveAlertTests` +2；删除 `predictReplyWindow` 及其 7 条纯自证测试。

第八轮之后又接了一处（§39），该处单独跑 `DeepStyle|Style|Autopilot|Prompt` 170 条全绿。

## 仍未处理（下一轮）

- 收件箱空态「没有没回的消息」在静默截断（`maxChats = 120`、逐会话 `try? … ?? []`）之后
  仍然宣称完整。
- `InsightCoordinator.swift:121-126` 的 30 分钟重算闸门是死的：把模型自由文本 `date`
  按 ISO8601 解析，通常得到 nil → `.distantPast`。
- 「等你回复」出现在你已经回过一句 Ack 的会话；「还没回」把纯 Ack 计为未回。
- `InsightHeroSection` 的 `totalMessages` 口径与按钮实际的「白名单 + 今天」范围不一致。

---

# 第九轮：那 1254 行没人见过的页面

上一轮把 `cross_topics` 接进洞察雷达后，按惯例要截图自查。截图时才发现一个更大的问题。

## 41. 整个洞察总览页从未被挂载

`InsightOverviewDashboard`（633 行）**没有任何构造点**——全仓 0 处引用。它是
`InsightRadarSection`(281) / `InsightAttentionBar`(125) / `InsightHeroSection`(117) /
`InsightKPIGrid`(98) 的唯一宿主，也就是 **1254 行界面 + `InsightRadar` 420 行算法**
（去重、脱敏、优先级分组、路由）全部在跑，全部没人能看见。

挂载点其实一直留在那里，名字就叫 `overviewDashboard`——但函数体是一句
`ContentUnavailableView("选一个对话")`。

处理：把真页面接回这个槽位，并在侧栏顶部加「总览」行做入口（`.task` 会自动选中第一个会话，
所以 `selectedChat == nil` 在真实启动里根本停不住；没有入口等于没挂载）。
默认落地页仍是会话详情，没有改成总览——那是产品取向，不是 bug，留给你定。

## 42. 截图看到的两处文案问题

- 空态写「先连上微信，再选有消息的日期和对话」，而侧栏此刻正列着 4 个已关注对话。
  微信明明连着，只是选中的时间范围里没有消息。改成按白名单判断：
  有已关注对话 → 「换一个时间范围或日期再看看」；没有 → 才说连微信。
  截图复核：新文案已生效，刷新/复制按钮在 0 条时正确置灰。
- 「生成今日摘要」下面写「根据 `overview.totalMessages` 条消息，列出该做的事和跨对话话题」，
  但 `totalMessages` 跟着页面的 范围(默认所有人) × 时间窗(可切近 30 天) 走，
  而简报实际只吃**已关注对话的当天结果**（`InsightCoordinator` 里 `insightPairs` 只取
  whitelist ∩ 今天）。选「所有人 + 近 30 天」时这句话能虚报一个数量级的读入量。
  改成不报数、只说规则：「把已关注对话今天的聊天，汇总成待办和跨对话话题」。
  `InsightHeroSection` 因此不再需要 `overview`，参数一并删掉。

## 43. 复制为 Markdown 总结

按钮原本没有对应实现（页面上一个按下去什么都不做的按钮，就是新的谎）。
补 `InsightOverviewReport.markdown(overview:briefing:)`，只用页面同一批数字，
跨对话话题段沿用雷达的「至少 2 个叫得出名字的对话」规则——报告不能比屏幕多说。

## 44. 跨对话行在渲染器里的字段错位（上一轮我自己埋的）

对着 `InsightRadarSection` 的四个固定标签（要知道/依据/意义/建议）复核上一轮的映射，
发现两处会立刻显形：对话清单被放进「意义」行（它是依据不是意义），
而 `actionLabel` 写「看对话清单」时清单其实折叠着、点开才看到。
改为：`依据` = 「A、B、C · 冲突原文」一行给全（超过 3 个写「等」），
`意义` 不编造（置 nil，渲染器自然不渲染），行首标签从「第一个对话名」改成话题名，
`建议` 给这一类单独一句「回之前先在这几个对话里把口径对齐」。
`radarNextStepText` 的兜底句是「我已在本卡片展开来龙去脉…」，对跨对话行不成立。

## 45. 挂载之后才看得见的排序问题

第一次截图里跨对话行根本没出现：它被排在同优先级的常规待办之后，第 6 条以外就没了。
一个「两个群对同一件事说法不一致」的发现，恰恰在最忙的时候最没用——这等于没接。
把 `crossTopic` 提到 priorityGroup 0 让 severity 说话：冲突（high）可以领先常规待办，
普通共同话题（medium）仍按 kind 排在「action」之后，不会挤掉一个真实的待回请求。
`CrossTopicRadarTests` 钉住这两半（冲突排第一 + 5 条待办一条不少）。

## 46. 让预览能真的渲染这一页

`overview.totalMessages == 0` 时整页只有空态，挂载了也看不到内容。补
`PreviewRuntime.previewChatStats()` → `InsightStore.applyProductPreviewFixture()`：
喂给页面的是**真的** `computeGlobalOverview` 结果，不是手抄一份数字的假概览，
否则截图验证的是一套和线上不同的算术。开关 `--preview-insight-overview`。

截图复核（`r9e-*`）：两条跨对话行都正常——link 图标、依据一行不折行
（「产品群、研发群、老板 · 产品群说周三上线，老板说周五」）、动作是「看建议 ⌄」
而不是会跳进单个会话的「打开对话」；冲突行红色「现在处理」，普通话题行「今天看一眼」。
下方「关系雷达」写明「分析至少两天后…单天分析不会填态度」，与空数据自洽。

未覆盖：窄窗（<800pt 的上下堆叠布局）没截到——预览窗口尺寸固定，没有改宽度的开关。

## 47. 头部标题不认得旁边那个选择器

`overviewHeader` 写死 `Text("今天聊了什么")`，紧挨着它的就是 今天 / 近 7 天 / 近 30 天 /
近 90 天 / 全部 的时间范围选择器，副标题还会老实地写「所有人 · 近 30 天 · …」。
选到近 30 天，标题仍然说今天。改成 `InsightTimeWindow.overviewHeading`
（`"\(rawValue)聊了什么"`），标题跟着选择器走，测试钉住五个档。

## 48. 本轮验证

新增 13 条（跨对话行 9 + 排序 1 + 复制报告 2 + 标题 1）。
`swift test --filter 'CrossTopicRadar|InsightRadar|Insight|Workspace'` 120 条全绿。
全量 `swift test`：1806 条、0 失败（15 条显式 skip）；`swift build -c release` 零警告。

---

# 第 10 轮：AI 摘要的新鲜度闸门 + 「没回的」页的完整性承诺

## 49. 那道 30 分钟闸门从来没关过

`InsightCoordinator.loadInsight` 开头写着「摘要还新鲜就跳过这一轮」，TTL 1800 秒。
它比较的时间戳来自 `ISO8601DateFormatter().date(from: briefing.date) ?? .distantPast` —
而 `briefing.date` 是模型自由文本的「日期」：prompt 要的是一个日期，模型回
`2026-09-18`、`2026年9月18日`、`今天`、空串都可能，ISO8601 解析一律 `nil`，
于是每次都落到 `.distantPast`，每次都被判成「无限旧」。
后果不是显示错误，是**每轮扫描都重跑一遍全白名单的 AI 批量调用** —
最贵的那条链路，闸门形同虚设。

改法：新鲜度是本地事实，就用本地时钟记。新增 `briefingGeneratedAt`（在赋值
`globalBriefing` 的同一刻写入）+ 注入的 `now`，判定收进
`nonisolated static func shouldSkipBriefingRefresh(force:briefing:generatedAt:now:ttl:)`。
「没有记录生成时间」按过期处理，不再按 `.distantPast` 处理 — 结论相同，
但不会再顺带把「有日期文本」的情况也拖进重算。

证伪：把调用点改回解析 `briefing.date`，`testRegenerationGuardIsFedTheLocalClockNotTheModelsDate`
的两条断言立刻红（窗口串里出现 `.date`、找不到 `briefingGeneratedAt`）。
只测那个纯函数是不够的 — 回归发生在调用点，不在函数里，所以额外钉了调用点。

## 50. 卡片上那个「日期」是模型随口说的

`InsightHeroSection` 的抬头是 `Text("AI 摘要 · \(briefing.date)")`。同一个自由文本字段，
在闸门上是 bug，在界面上是承诺：用户读到「AI 摘要 · 2026-09-18」会以为那是生成时刻，
而它可能是模型抄的、也可能是它编的。改成 `InsightBriefingCaption.text(generatedAt:now:)`：
刚刚 / N 分钟前 / 今天 HH:mm / M月d日，全部来自我们自己的记录；没有记录就只写「AI 摘要」，
不假装有时间。跨天判断用 `Calendar.isDate(_:inSameDayAs: now)` 而不是 `isDateInToday` —
后者读真实日历，注入的时钟骗不过它（这条在测试里真的把日期滚过一天才暴露）。

截图复核（`r10d-lower.png`）：抬头渲染成「AI 摘要 · 22 分钟前更新」，一行不折。
为此临时放开过一次 `private(set)` 让预览能写时间戳，截完已还原（两个文件都用 `cp` 回滚）。

## 51. 「没有没回的消息」是一句完整性承诺

`ScanEngine+MissedReplies` 有两处静默：`maxChats = 120` 之外的对话直接不查，
逐会话读取用 `try? … ?? []` — 读失败和真的没消息，在下游长得一模一样。
空态文案却写「这段时间里，关注的私聊和点名你的群消息都回过了。」，
标题写「没有没回的消息」。查了一半和查完全，界面同一句话。

改法：扫描返回 `(items, coverage)`，`MissedReplyFinder.Coverage` 记
`examinedChats / unreadableChats / unexaminedChats / groupSessionsUnavailable`，
`caveat` 给一行「另有 N 个对话没读到，这里可能不全。」。
界面只加一个槽位：有结果时是胶囊下方一行（配 `exclamationmark.triangle.fill`，
`r10b-crop.png`），空结果时直接接管空态的标题与说明 — 标题从
「没有没回的消息」换成「没查全」（`r10c-crop.png`）。搜索没命中的第三种状态
保留自己那句解释，不被这条披露污染。

顺带把双重否定的标题一起清了：「没有没回的消息」→「没有遗漏」，
说明行仍是那句完整的话。

## 52. 只回了一句「收到」，页面说你没回

`MissedReplyFinder.buildItem` 里 `answered` 要求实质回复，ack（「收到」「嗯」）不算 —
这是有意的（`Models.swift` 的 `.unsubstantiveReply` 就是为它建的）。但卡片上没有任何
痕迹，用户看到的是「这条我完全没回」，而他明明回过一句。算法没错，界面少了一半真话。

给 `Item` 加 `repliedWithAckOnly`（第一条未回 inbound 之后存在 ack 出站即为真），
卡片徽章直接复用收件箱那个词的常量：`ReplyDebtReasonCode.unsubstantiveReply.label`
= 「未实质回应」。两个界面对同一件事说同一句话。截图 `r10e-badge-crop.png`：
「@ 我」+「未实质回应」并排，未挤掉「N 条」的位置。

## 53. 「这几个对话」不数数

`r10d-lower.png` 里冲突行的标题是「「上线时间」在这几个对话里说法不一致」，
紧下面依据行老实列出「产品群、研发群、老板」。数量是算法已知的（`chats.count`），
非冲突那条也一直在写「在 2 个对话里都在讨论」。改成两条都带数字，测试跟着更新。

## 54. 本轮验证

新增 16 条：`BriefingFreshnessTests` 9（含调用点钉桩 + 抬头文案 + 源码扫描）、
`MissedReplyCoverageTests` 7（其中两条走真实 `WeChatReader` + 真实 `ScanEngine`，
证伪过截断计数：把 `unexaminedChats` 写死 0，两条断言同时红）、
`MissedReplyFinderTests` +3（ack 只回 / 沉默 / ack 早于提问）。
`CrossTopicRadarTests` 1 条改期望。

一个假设被证伪并记录在案：我以为 `getSessions()` 在读不到时会抛，从而验证
`groupSessionsUnavailable` 这条分支。合成夹具下它不抛 — key 缺失时直接 `return []`，
写个假 `session.db` 也不抛。分支保留（它替换的是原有的 `try?` 吞异常，不是新增分支），
但本轮没有测试真的走到它，不把它算作已验证。

预览开关补两个：`--preview-today-missed`（今天页停在「没回的」这一段，原本只能点击到达）、
`--preview-missed-partial`（喂一份截断过的 coverage，让「没查全」这一态可截图）。

## 55. 仓库自己的门禁逮到了我这一轮的新代码

全量跑第一遍是红的：`ChromeMotionHygieneTests.testReadableChromeDoesNotGoBelowTenPoints`
报 `MissedReplyFeed.swift still draws readable chrome below 10pt (.font(.system(size: 9)` —
我给那行披露配的警示三角写成了 9pt。这个扫描是早几轮立的规矩（Views 下不许出现 6–9pt 的
可读 chrome），这次正好验证它不是装饰：改 10pt 后重截 `r10f-crop2.png`，三角与 11pt 文字
基线齐平、不折行、左缘与卡片对齐。

## 56. 本轮收口数字（§57、§58 之后重跑）

全量 `swift test`：XCTest 1826 条 + swift-testing 70 条，15 条显式 skip，0 失败；
`swift build -c release` 零警告。本轮新增 21 条测试（新鲜度 9 + 完整性 7 + ack 3 +
收件箱计数 4 中的净增）、改 4 条期望、删 1 条走不通的合成夹具用例（见 §54 证伪记录）、
删掉一个没有读者的枚举载荷（§57）。

## 57. 收件箱头部那个数字不数它下面的列表

重截岛展开态时盯着一张 00:00 的旧图看了很久：抬头写「待处理 (1)」，底下三行
（一条私聊 + 两个群 @）。这不是渲染延迟，是算术：`InboxHeaderState.listedCount`
给的是**胜出类别**的条数（action 桶），而 `ForEach` 画的是 action + fyi + passive
三桶。上一轮把「1 条紧急 over 三行」修成「整个 action 桶 over 三行」，修了一半。

`InboxPresentationPolicy` 里 `actionItems/fyiItems/passiveItems` 三个过滤器原本在
`visibleItems` 和 `hiddenPassiveUpdateCount` 里各抄了一遍，现在收成 `buckets(_:)`
一处，头部数字改读 `pendingCount`（三桶之和 = 列表所代表的全集，折叠的
「还有 N 条普通更新」也算在内，那一行自己会说明）。
顺带发现并修掉同源的第二个漂移：`inboxHeaderState` 判「群里@了你」用的是
`messageType == .groupMentionFYI`，而列表用的是 `semanticState`；已被用户处理掉的
@ 仍会让横条说「群里@了你」，而列表里那一行早没了。现在两者共用 `buckets`。
`InboxHeaderState` 的 Int 载荷随之没有读者，删掉，只留类别。

证伪：`pendingCount` 退回只数 action 桶 → 4 条失败；`buckets` 的 fyi 判据退回
`messageType` → 2 条失败（横条用词 + 计数）。`cp` 还原后全绿。

## 58. 治具自己埋的坑：旧截图会被当成新证据

`/tmp/wcsnap.sh` 只删 sentinel，不删 `$TMPDIR/wechathud-*.png`。岛展开收件箱那一态
（`inbox-closed`）已经不再被产出，于是脚本把 00:00 的旧图当新结果复制了三份，
我差点据此判定 §57 的修复无效（三张 md5 完全相同才看穿）。脚本已改成先清旧图。
真正的空洞记在这里，下一轮先补：`--preview-expand-row` 现在截到的是一个空壳药丸
（面板没停在展开态），岛展开收件箱这一态在预览里不可达 —— 而它是这个 App 被看得
最多的一个面。§57 的正确性目前只有单元测试与证伪撑着，没有像素证据。

---

# 第 11 轮：岛展开态从第 7 轮起就没真的画出来

## 59. 一个不依赖帧驱动的最后期限

为了补 §57 欠的像素证据去重截岛展开态，结果拿到一张只有黑色药丸、其余全空的图。
先怀疑截图，后拿数据：在 `captureSurfaces` 里打一行面板状态，得到

```
frame=(584,861,560×256) cur=extended pres=extended items=3 painted=(715.5,1085,297×32)
```

窗口已经涨到展开尺寸（560×256）、状态是 extended、收件箱有 3 条，
但**遮罩揭示的矩形还停在收起态的 297×32 药丸**——展开的收件箱整个被 mask 掉了。
`WCHUD_ANIMATION_DEBUG=1` 的轨迹给出同一结论：`>>> START ... from=297×32 to=560×256`
之后再没有 END，也没有任何 tick。

根因是第 7 轮把帧驱动从 `Timer` 换成 `CADisplayLink` 时，把「跑完了」的判定
（`weldedToTarget` 与 `IslandMotion.maxRunDuration` 的楔死上限）**全留在了 tick 回调里**。
display link 不送帧（这台机器上无录屏权限的 headless 环境就是这样；真实机器上窗口被完全
遮挡 / 显示器休眠同样是这个形状），回调不再执行，run 永远不会结束，遮罩就永远停在旧药丸上：
一个「已经展开但什么都看不见」的岛。

仓库其实已经认过一次这个形状：`IslandMeasurement.landsWithoutMotion` 规定
「面板不可显示时直接落地，不要起 spring」，理由写的就是「显示链接不会 fire，run 会冻在
起始 rect 上」（`IslandFrameVisibilityTests` 里那条中文断言）。那条规则盖住的是
「被 orderOut 的面板」，没有盖住「在屏上但拿不到 vsync」——headless 截图环境正是后者，
窗口可见、`isDisplayable` 为真，于是照样起了 spring，照样没有帧。

修法是把最后期限从帧驱动里拿出来：`armFrameAnimationWatchdog()` 在 run 启动时挂一个
`maxRunDuration + 0.05` 的单发 Timer（`.common` 模式），只负责收尾，不参与运动；
健康的 run 仍由自己的 tick 结束并把它 invalidate。`finishFrameAnimation` 与
`cancelFrameAnimation` 两处出口都失效它。有了这条兜底，`landsWithoutMotion` 判错的
（或来不及判的）场合也不会再把岛留在空遮罩上。
`IslandFrameVisibilityTests.testFrameRunHasAnExitThatDoesNotNeedFrames` 钉住这条不变量。
它第一版是空的：`source.contains("armFrameAnimationWatchdog()")` 光看声明就为真，
删掉调用点仍然全绿——证伪跑一遍才暴露，改成数「声明 + 调用 = 两处」。

修完重截（`r11-land-island-auto.png`，87KB 对比空白 15KB）：展开收件箱完整渲染，
并且顺带补上了 §57 欠的那张证据——抬头现在写 **待处理 (3)**，底下正好三行。

如实记录边界：我无法证明真实用户的机器上 display link 会停，但「不送帧就永不落地」这个
失败形状本身值得修；而在此之前，第 7 轮之后所有岛展开态的像素复核都是不可得的
（这也是为什么上一轮只能拿单元测试给计数修复背书）。

## 60. 岛底栏那两个没人看得懂的图标

展开态底栏一直是两个纯图标：`checklist` 和 `macwindow`，含义只写在 tooltip 里
（`r11-corner.png` 放大后更明显：一个列表勾、一个带三个点的方框，后者看着像占位符）。
这是岛上一整块常驻 chrome 里唯一的「必须先悬停才敢点」的东西，而 560pt 宽的栏右侧全是空白。
改成图标 + 文字：「待办」「查看全部」（`r11-bar-crop.png`）。
`barIconTarget` 从固定 22×22 方框改成 `minHeight`，整条标签都是命中区，比原来更宽。
help/AX 文案不动，`forbiddenChrome` 里禁用的「工作台」一词没有出现在界面上。

## 61. 还欠的（岛这一面）

`--preview-peek` 序列里 `peek-landed` 那张落在过渡帧上（药丸只揭示出一小段底栏），
peek 这一态的像素复核仍然不可靠；`--preview-expand-row` 走的也是同一套展开时序，
现在能落地但截图时机敏感。下一轮要么把 capture 时机改成「等到 run 结束事件再拍」，
要么给预览一个显式的「动画已停稳」闸门。

## 62. 本轮验证

全量 `swift test`：XCTest 1827 条 + swift-testing 70 条，15 条显式 skip，0 失败；
`swift build -c release` 零警告。新增 1 条不变量测试（§59 的看门狗），删 1 处只增不减
也无人读的枚举载荷（§57）。像素证据：`r11-land-island-auto.png`（展开收件箱重新可见 +
待处理 (3) 对上三行）、`r11-bar-crop.png`（底栏带文字）、`r11-corner.png`（改动前的两个裸图标）。

## 63. 截图时机闸门：`waitForIslandToSettle`

§61 欠的那条这轮补上了。预览序列里所有岛截图原本都挂在固定延时上（1.2s / 0.28s /
0.55s / 0.9s），reveal 是 spring，固定延时既可能拍在半路，也可能在 run 还没挂上之前拍，
于是把上一态的形状当成新态存档。现在 `PreviewRuntime.waitForIslandToSettle` 要同时满足
三条才放行：过了 `minimumWait`（0.35s，覆盖「测量下一拍才起 run」）、面板报
`isFrameAnimationRunning == false`、揭示尺寸连续两拍不变。上限 `cap` 3.0s 必须大于
§59 那条看门狗的 2.55s，否则闸门会停在「等帧」的空档里，反而拍到落地前的一帧。

第二条判据是这轮实测逼出来的：有一次截图里 contentView 高 422pt、窗口只有 339pt，
mask 也停在 339——动画已经停了，但 surface 的测量晚一拍到，量完又重挂了 spring。
只看「动画停没停」不够。加了尺寸判据之后，五张截图的 `bounds` 与窗口 frame 全部对齐。

## 64. display link 收不到帧时，岛不再空等 2.55 秒

做闸门时顺手量到一组说不通的数字：`durationMs 1665 / fps 0`。查下来不是环境问题，
是产品形状——`contentView.displayLink` 只在视图真能画进某块屏时 fire，**屏幕休眠时一帧
都不送**（这台机器现在就是 `Display Asleep: Yes`，`CGGetActiveDisplayList` 返回 0 块活动
显示器）。§59 的看门狗让 run 会结束，但结束意味着：遮罩在原地停 2.55s，然后啪地跳到
目标。展开收件箱对用户变成一段死寂，不是动画。

现在起架时同时挂一个 2 个 vsync 的探针（`armFrameDriverProbe`）：到点如果一帧都没收到，
就把同一个 spring 交给 runloop 时钟驱动（`installTimerFrameDriver`，也就是 display link
之前的那条路）；链接只要 tick 过一次就立刻撤探针，绝不降级健康的 120 Hz。看门狗保留，
作为「连 timer 都不 fire」的最后一道。实测 trace：

```
@001339.7ms >>> START 297×32 → 453×32
@001377.9ms display link delivered no frame — switching to timer driver
@001395.5ms firstTick 55.2ms after run start
@002060.4ms frameAnimationEnded   (335ms, 21 帧)
```

两条前置证伪，都记下来免得下次再当成 bug 查：`WCHUD_ANIMATION_DEBUG=1` 是**慢动作**
（`isSlowMotion`，时长 ×5），要看真速得用 `=fast`；`fps 0` 是 `IslandFrameTiming.begin()`
清掉当前样本的老坑（第 7 轮就写过注释），读 `completedRuns` 才是发生过的事。

## 65. 一次动画的「时长」和它的「帧样本」不是同一段

修完降级，数字自相矛盾：`duration 336ms` 却带着 `38` 个 16.7ms 的样本（合 665ms）。
根因在重定向分支：`run.startedWallClock = Date()` 每段都刷新（楔死上限该如此，健康重定向
不该被截断），但 `IslandFrameTiming` 的样本**跨重定向连续**（spring 保速、tick loop 不重启）。
于是上报时长只算最后一段，样本算全程，`fps` 跟两者都不符。

`SpringRun` 增加 `motionStartedWallClock`（只建架时写一次），`finish(duration:)` 读它，
楔死判据仍读 `startedWallClock`；`IslandFrameTiming` 补 `ticksForCurrentRun`（第一帧只有
tick 没有 interval，读 samples 会把活着的链接误判成饿死）与 `totalTicks`。悬停展开现在
自报 **737ms / 39 帧 / 57.1fps / p95 18.6ms**，两段（药丸加宽 336ms + 转向收件箱）加起来
正好对上样本总数。worst 61ms 那一下落在 `captureSurfaces` 写三张 PNG 的主线程开销上，
不是产品掉帧——所以这份 JSON 里该信 `p95Ms`，`worstMs` 在预览环境里被截图自身污染。

`IslandFrameVisibilityTests` 加 3 条：探针确实挂在每次起架、探针只在零帧时降级、链接首帧
必须在步进之前撤探针、时长从运动起点量而楔死从最后一段量。前两条各做了一次变异证伪
（删掉 `installTimerFrameDriver()` 调用、把 `motionStartedWallClock` 换回 `startedWallClock`），
两条都如期失败。

## 66. 动画路径的截图是黑盘：治具边界，不是产品缺陷

闸门装好后第一张 `peek-inbox` 是全黑（1120×512，非黑像素 0.0%，颜色数 1）。逐项查下来
视图树是对的：`bounds 560×256`、mask `(0,0,560,256)` 不透明白、hosting view 下 16 个子视图
且收件箱的图标/按钮都在 560×256 里各就各位——**只有像素没有**。同一状态走
`--preview-expand-row`（首次落地是 `landInstantly` → `setFrame(display: true)`）拍出来是
90KB 的完整收件箱。差别只在「这个 surface 是动画挂上来的，而它挂上来之后从没被 display
过」；屏幕休眠 ⇒ 没有刷新 ⇒ `cacheDisplay` 拍到空图层树。依次试过 `layoutSubtreeIfNeeded`、
`needsDisplay` + `displayIfNeeded`、`panel.display()`、`setFrame(_, display: true)`、
`displayIgnoringOpacity(_:in:)`——全部无效，且 `setFrameInstantly` 在 stage 已经够大时
根本不会走那次 `display: true`。

结论按边界写死在 `runPeekMorphCapture` 的文档注释里：**展开态的像素看
`--preview-expand-row`，动画的数值看 `--preview-peek` 的 JSON**（后者的几何、mask、
帧样本仍然全对）。这轮为此删掉了三处「顺手加上的」治具代码，没留假修复。

## 67. 展开的行动条读起来像「第四行消息」

`r12-row-island-row-expanded.png`（第一次真正拍到停稳的行展开态）：点开的 AI 面板顶部有一
条 `Divider`，和行与行之间的分隔线一模一样，于是「这一行的展开」被读成「又一条消息」；
面板里还留着一个 `EmptyView()`，它在 `VStack(spacing: 10)` 里真的占了一格间距。

去掉顶部分隔线，换成 2pt 薄荷左沿（`CompanionPalette.islandMint.opacity(0.5)`，和标题
「AI 认为…」同色），删掉那个 `EmptyView()`。实测面板带 100pt → 81pt，岛总高 338pt；
左沿像素探针确认落在 x=1..2（`93,123,113`），第一次提交时它只有 10pt 高——`Rectangle`
的 ideal 高度是 10，`.frame(width: 2)` 不锁高度，补 `.frame(maxHeight: .infinity)` 后才
铺满整条带。

## 68. 本轮验证与仍欠的

相关 6 个套件 54 条全绿（`ChromeMotionHygiene` / `PrimaryActionStyle` /
`InboxActionPersistence` / `IslandInteraction` / `PreviewHarnessHygiene` /
`IslandFrameVisibility`），`swift build` 零警告。产品侧改动两处：display link 饿死时降级
（§64）+ 行动条分组（§67）；测量口径一处（§65）；治具一处（§63 闸门、§66 边界记录）。

还欠：`peek` 这一态按设计没有「停稳帧」（它就是 dwell），所以它的像素只有 mid-dwell 一张，
`r12-peek-island-peek-hover.png` 里能看到药丸两翼 + 中间缺口，但 mask 停在 455.7×31.5 的
半帧上；窄窗（<800pt）洞察总览仍无法截；我答应的事 / 今日小结 / 关系雷达 / 自动托管面板 /
对话详情 / 通知横幅 / 上手指南 / 审批工作区这 8 页仍未逐像素复核。

## 69. 工作区四页首次逐像素：今日小结 / 我答应的事 / 关系雷达

闸门装好后第一次能把工作区页面当证据看。三处产品缺陷都在像素上确认、修完再截一次确认：

**a. 到期时间自创缩写（`DailyReportCommandCenterView.deadlineText`）。** 这一页写的是
「6时前到期」「59分后」，而全站 `ViewHelpers.formatRelative` 是「3 小时前」。不只是不统一：
「6时」在中文里先读成钟点（六点钟），「6时前到期」能被读成「6 点之前到期」，意思正好反了。
改成「6 小时前到期 / 59 分钟后 / 1 天前到期」。前后对比：
`r12-dailyReport-workspace-auto.png`（旧）→ `r12-report-workspace-auto.png`（新）。

**b. 同一个建议印两遍。** 「本地统计」那块第一行结尾是「优先处理：确认待办责任人的展示规则。」，
第二行紧跟着「先处理紧急事项：确认待办责任人的展示规则。」——`narrative` 和 `tomorrowFocus`
各自挑了同一条 action。改成先算 `tomorrowFocus`，`narrative` 若要点同一条就不点（保留
「最高风险」优先的既有次序）。新截图里第一行只剩统计事实。

**c. 焦点环停在没打开的那一页。** 侧栏是手搓的，键盘焦点环也是手搓的
（`companionFocusRing`，用的 `keyboardFocusIndicatorColor`，所以看着就是系统蓝）。窗口
初次成为 key 时把首焦点给了第一行，于是打开「关系雷达」时环画在「今天」上——比选中的
行高两格，读起来像「今天」才是当前页。`.task { focusedTab = selectedTab }` 把首焦点交给
当前页。像素判据（侧栏区蓝色环所在行）：修前 y=181…250（今天），修后 y=657…726（关系雷达 /
今日小结，即选中行）。中途试过 `.focusEffectDisabled()` 和 `.onAppear { focusedTab = nil }`，
前者基于「那是系统环」的错误假设（实测环会跟着 `focusedTab` 走，是我们自己画的），后者
在 SwiftUI 赋首焦点之前跑完、无效——两处都已删掉，不留假修复。

**d. 空态文案断行。** `ContentUnavailableView` 的描述列很窄，「先在「聊天回顾」里分析至少
两天。单天分析不会填态度。」折成三行，最后一行只剩「态度。」。改成显式两行
「先在「聊天回顾」里分析两天以上 / 单天分析不会填态度」。

顺带记录两条**不改**的判断：「我答应的事」顶部那句「不受「待办」页保留档位的影响」是第 9
轮为消除两页互相矛盾而写的，删了会退回原问题；右上角「一键清空」标签确实含糊，但它有
确认框且框里点名范围（`CompanionDialog(title: "一键清空当前承诺？")`），风险已被兜住。
「今日小结」里同一条承诺在两个对话各出现一次（林晓 / 项目协作群，都是 7 小时前到期）是
真实数据，跨对话去重会丢信息，不动。

验证：`DailyReport* / *Settings* / *Workspace*` 相关 8 个套件 77 条全绿；本轮没为 b/c 补
新测试（b 是文案去重、c 需要真实 key 窗口才能断言），证据是上面的前后截图。

## 70. 「每小时最多」管的不只是自动回复

第 13 轮从「自动发出去关着时，把握程度/每小时最多这两个控件是不是死控件」这个问题开始。
差一步就动手把它们 disable 了——查代码才发现闸门不是只服务自动路径：

- `serialSendWithRateLimit`（`AutopilotService.swift:1111`）里滚动一小时计数 `globalSendTimestamps`；
- 两个调用方：`:516` 是自动路径，**`:1400` 在 `executeSend` 里**——也就是用户在「待确认回复」
  手动点确认后的那条发送，走的是同一个闸门。

所以关掉自动发送时「每小时最多」不是死的，反而是**唯一还在生效的发送限制**，而界面文案写的是
「所有对话加起来每小时最多发这么多条，超了就等下一个小时」：既没说它也管人工确认，又承诺了一
个不存在的整点重置（窗口是滚动的）。用户撞上这堵墙时看到的提示还写着「已达到每小时**自动回复**
上限」——自动回复根本没开。三处一起改：hint 点明两种发送都算、去掉整点重置的说法、提示改成
「已达到每小时发送上限」。

新增 `testHourlyCapCopyCoversManualSends` 把文案钉在代码上：hint 必须提到「确认后才发」、不许
再出现「等下一个小时」，且 `executeSend` 体内必须真的有 `serialSendWithRateLimit(`（哪天人工
路径绕过闸门，这条文案就又是假的），并禁止旧提示串复活。两次证伪：把 hint 改回旧句 → 2 条失败；
把源码锚点 `func executeSend` 改成不存在的名字（测「测试本身会不会空过」）→ 1 条失败；恢复后全绿。

顺带一条**没改**的判断：「自动发送把握程度」确实只在自动路径生效（`confidenceThreshold` 只被
`autopilotSafetyHoldReason` 读，调用点在 `:841` 的自动链路上），但它的副标题已经写明「达到这个
门槛才会尝试自动发送」，再叠一层 disable 只是把一行字变成看不见的控件——没动。

## 71. 通知横幅终于有了像素，并修正 §66 的过度概括

`--preview-notification` 其实早就存在（`PreviewRuntime.swift:316` 用 `holdSeconds` 顶住不自动
收起），前 12 轮一直没用它截过图。`r13-banner-island-auto.png`：580×148 的横幅，头部
「行 周然 @你 · 行业合作-小程序业务交流群 · 刚刚」+ 休眠/关闭两个图标，正文三行大字，非黑像素
14%、36 种颜色。逐像素看完**不需要改**：notch 带、字号、群名截断、两个图标的位置都对。

更重要的是它证伪了 §66 写下的机制解释：横幅也是「动画挂上来的新 surface」，同样在屏幕休眠的
会话里，却拍得出来。所以「新挂载 + 无刷新 ⇒ 黑盘」不是成立的原因，至少不是唯一条件；上一轮
写进 `runPeekMorphCapture` 文档注释的因果句已经改成只陈述观察（收件箱那张拍不出、横幅拍得出、
四种强制 display 手段都无效、像素走 instant 路径），不再留一个我没证明的机制。

## 72. 「怎么用」页同一句话印两遍

`r13-guide-workspace-auto.png`：第 3 步的副标题「「今天」里看待回和待办。」和下面「每天怎么用」
卡片第一行「看待回和待办。点开一条消息看原文和摘要。」是同一句话，隔 300pt 印两遍。改成
「岛上报数，这里列明细。」——说的是这一页和岛的关系，卡片里没讲过。

写第一版时我落了一句「岛上报几条待回，「今天」就列几条」，被自己的截图否掉了：r12 的岛截图上
药丸写「1 条待回」，展开收件箱却是「待处理 (3)」——药丸只数待回，这一页还列待办。这句留在
代码注释里当下次的护栏。

## 73. 待确认回复页：看完不改

`r12-autopilotDashboard-workspace-auto.png`（首次逐像素）。筛选项只在「待确认 0」上带计数、
右上「尚未开始整理 · 自动发送关闭 · [开始整理]」三态、空态直接指回「开始整理」。和「我答应的
事」页的计数规则一致（只在有可动作的项上给数），没有互相矛盾的承诺，也没有重复句子。判定：
本轮不动，避免为了「每轮都要有 diff」而改。

## 74. 本轮验证

全量 `swift test`：XCTest **1831 条 / 15 skip / 0 失败**，swift-testing 70 条全过；
`swift build -c release` 零警告通过（65.35s）。新增 1 条文案↔算法不变量测试（两次变异证伪），
产品文案改动 4 处（每小时 hint、发送上限提示、guide 第 3 步、§71 的注释纠偏），代码行为改动 0 处。

## 75. 岛的详情态：第一次拍到，当场三处改

`--preview-detail`（`PreviewRuntime.swift:951`，`AppDelegate.swift:824` 接线）把
`PanelState.showDetail(kind: .conversation(...))` 打进岛的 surface。前 14 轮 compact / peek /
extended / notification 都有截图开关，唯独这个 500pt 高的详情页——用户点一行就到的那一页——
从来没被拍过。`r14-detail-island-auto.png`（700×500pt）是第一张。

拍出来立刻看到三处：

1. **右上角叠了两个关闭按钮。** `ConversationDetailView` 的 header 尾部有一个 `xmark`
   （旧 :424-431），`DetailPanelView` 又在同一个角用 `ZStack(alignment: .topTrailing)` 盖了
   一个 `xmark.circle.fill`（`DetailPanelView.swift:63`）。后者画在上面，前者**任何鼠标位置都
   点不到**——像素上右上角只有一个图标，代码里有两个。删掉 header 那个（`ConversationDetailView`
   全仓只有 `DetailPanelView.swift:38` 一个构造点，不存在别处还在用）。
2. **`pencil.circle` 在 11pt 下退化成一个圆圈加一道斜线**，读起来是 ⊘「禁止 / 不可用」，
   而且就贴在会话名后面。换成不带圆圈的 `pencil`（同尺寸 semibold + 18×18 命中框）。
3. **默认态在写「未发送」。** 输入框里还没发出去的内容当然是未发送，这一行在用户什么都没做
   时报告的是初始条件，不是状态。改成只在有回执时才出现（`sendSucceeded || sendResult != nil`），
   保留下面那句「发送前会让你确认收件人和内容。」——那句解释了「发送…」为什么带省略号，是有用的。

判定依据都在图上，没给这三处补测试：它们是「这一帧长什么样」的问题，测试读不到像素，
而这三帧现在有了固定的开关可以重拍。

## 76. 会话名被自己的兜底遮蔽（算法修正）

第一版截图上标题写的是 **`preview-project · 群聊`**——把内部 id 印在最大的字上。
根因在 `ChatMonitor+ChatNaming.swift:28`：`reader.displayName(for:)` 在联系人缓存为空时
（切号后、首次 refresh 前）直接把 username 回显出来，而下一行的判据是
`resolved.isEmpty || isRawChatIdentifier(resolved)`。`zhangsan2024` 这种老微信号既不是
`@chatroom` 也不以 `wxid_` 开头，**形状上不像 id**，于是判据放行，hud 自己库里存着的
`contacts.display_name`（这里就是「项目协作群」）永远轮不到。§40-44 那段注释说的
「daily report 里出现 preview-colleague」是同一个洞，当时只补了 `isRawChatIdentifier`
为真的那一半。

修法是把「reader 把 username 原样回显」也算作无信息：`resolved == chatUsername`。
兜底顺序不变（alias → reader → contacts → whitelist → 占位/username），只是让后两级
在 reader 只会念 id 的时候有机会说话。

新增 `ChatNamingTests.testUsernameEchoFallsBackToStoredName`（空联系人库的 reader + 有名字的
store ⇒ 期望「张三」）和 `testUnnameableChatStillFallsBackToItsUsername`（什么都没存 ⇒ 仍然
返回 username，不发明占位符）。变异证伪：把 `resolved == chatUsername` 去掉，前者报
`("zhangsan2024") is not equal to ("张三")`；恢复后 25/25 过。

## 77. 窗口下限 900pt 从没被拍过，一拍就裁字

`--preview-narrow=<pt>`（`PreviewRuntime.swift:967`）+ 同目录写出的
`wechathud-window-qa.json`（`requestedWidth` / `achievedWidth` / `clamped`）。

先要解释为什么需要它：`SettingsWindow.swift:85-89` 原来内联写着
`--preview-compact` → `setContentSize(820×620)`，但同一个文件 :69 把 `window.minSize`
设成了 900×580，AppKit 会把 `setContentSize` 钳回下限。**这个开关一直是空转的**，
它交出来的截图看起来像「820pt 通过」，实际量的是 900pt。新开关先放松 `minSize` 再改宽度，
并把「请求宽度 / 实得宽度 / 是否被钳」写进 json，空转这件事以后藏不住。
（`--preview-compact` 全仓无引用，删掉；注释留在原处。）

`r14-narrow-workspace-auto.png`（760pt，低于下限，作为「为什么下限是 900」的证据保留）和
`r15-w900-workspace-auto.png`（正好是 app 自己声明的下限）暴露同一个缺陷：
洞察总览 header 右侧那个 5 段的时间窗选择器写死 `.frame(width: 280)`，**「全部」被右边界
从中间裁断**。900pt 是用户能拖到的最窄处，所以这不是越界测试，是可达缺陷。

`InsightOverviewDashboard.swift:74` 改三处：
- 副标题不再重复两个选择器本身的内容（原来写「所有人 · 今天 · 2 个活跃对话 · 138 条消息」，
  右边 200pt 内就摆着「所有人」和「今天」两个选中段），只留计数；
- 左侧标题块 `.frame(maxWidth: .infinity, alignment: .leading)` + `lineLimit(1)`，让它让位
  而不是撑位；右侧 `.fixedSize()` 保住 280；
- 整行 `.frame(maxWidth: .infinity)`——它在外层**纵向** ScrollView 里，横向溢出是被裁而不是
  被滚，不接受 proposal 就会按 ideal 宽度排，ideal = 标题 + 280 > 视口。

900pt 重拍：「全部」完整落在 24pt 内边距里；1180pt（`r15-w1180-workspace-auto.png`）
两栏布局未受影响。这一处同样只用像素判定，没有补测试。

顺带记一个工装缺陷：`/tmp/wcsnap.sh` 里 `rm -f $TMP/wechathud-*.png $TMP/wechathud-*-qa.json`
在 zsh 下只要有一个 glob 不匹配，**整条 rm 就不执行**（`no matches found`），于是旧 PNG
留在原地，脚本的「文件数稳定即完成」循环立刻满足，之后每一轮复制的都是上一轮的图。
本轮 r14-detail 有两次就是这样拿到旧像素、把「改了没生效」误判成「改了没生效」。
现在脚本 `setopt NULL_GLOB`，并且复制前用 stamp 文件做新鲜度门禁：本轮没写出的图一律
`NO FRESH CAPTURE` 退出，不再往 `docs/qa/` 里放旧证据。

## 78. KPI 卡上那句「注意力偏离」是永远改不掉的判决

`InsightKPIGrid.swift:15`：`VIP 占比 < 10% ⇒ 「注意力偏离」（橙色）`，否则「合理」。
分母是用户自己标出来的 VIP 会话数——只把一位同事设成 VIP、同时关注一百个群的人，
无论怎么回消息都会被判「偏离」。这不是可以行动的建议，是一个去不掉的差评，
而且算法里没有任何东西支持「偏离」这个结论（`ChatInsightEngine.swift:214` 只算了
`vipMessageRatio = VIP 消息 / 总消息`）。

改成陈述口径：`N 条 / 共 M 条`，状态色转 `neutral`。同一屏上「非工时占比」「回复率」
「承诺履约」三张卡也带阈值判决，那三张**保留**：它们的分母是行为本身（几点发消息、
回没回、有没有到期），用户能改变它；VIP 占比的分母是用户的关注列表，改不了。
这条边界记在这里，下次别再往「改不了的量」上刷颜色。

验证方式说明：这张 KPI 卡在总览的滚动折叠区以下，本轮的截图开关只能拍到视口内，
所以它**没有像素证据**，只有二进制级证据（`注意力偏离` 在 `WeChatHUD` 里 0 命中，
`条 / 共` 1 命中）。要拍到需要再加一个滚动预览开关，留给下轮。

## 79. 本轮验证

- 全量 `swift test`：XCTest **1833 条 / 15 skip / 0 失败**（上轮 1831，+2 来自 §76），
  swift-testing 70 条全过。
- `swift build -c release`：第一次跑因为我在构建过程中改了 `InsightKPIGrid.swift`，
  swift 直接报 `input file was modified during the build` 并失败——这是构建系统的正确
  行为，不是代码问题。改完后重跑：**exit 0，`warning:` 0 命中，65.63s**。
- 产品改动：算法 1 处（§76 名字回显判据）、布局 4 处（§75 删重叠关闭按钮、
  §75 pencil 图标、§77 header 三处宽度约束）、文案 3 处（§75 默认态「未发送」、
  §77 副标题去重、§78 VIP 判决）、预览工装 3 处（`--preview-detail`、
  `--preview-narrow`、删空转的 `--preview-compact`）。

## 80. 滚动开关 + 折叠开关：KPI 卡第一次进像素

两个新预览开关，都是为了补 §78 留下的"看不见"：

- `--preview-scroll=<pt>`（`PreviewRuntime.swift:1006`）：从 AppKit 侧找出 workspace
  窗口里面积最大的那个 `NSScrollView`（SwiftUI 的 ScrollView 在 macOS 上就是它），
  `contentView.scroll(to:)` + `reflectScrolledClipView`。故意**不**去给每个页面加
  `ScrollViewReader` 锚点——只有"记得挂钩的地方"能滚的开关，等于在别处悄悄只拍页首，
  而截图看起来仍像通过。achieved/requested 偏移和 `documentHeight` 写进
  `wechathud-scroll-qa.json`（实测 3 个 scroll view、偏移 900 全兑现、文档高 1610→2360）。
- `--preview-expand-modules`：判定点写在 `collapsibleSection` 自己身上
  （`InsightOverviewDashboard.swift:391`），不是去维护一份"模块 id 清单"。清单会在有人
  新加一节的那一刻过期，而过期的表现正是"那一节从没被拍过"。

`r16-kpi-workspace-auto.png`：洞察总览 6 张 KPI 卡第一次进像素。**一屏就撞出三个只有
拍下来才看得见的缺陷**（见 §81）——这就是前 15 轮一直被跳过的代价。

## 81. KPI 卡：分母为空时不许打分

1. **「消息总量 138」下面写「-100% 近期偏闲」**。这个数是两个日均值的比
   （`recent7d 日均 / 全窗口日均`，`ChatInsightEngine.swift:389-391`）被包装成百分比涨跌，
   而 -100% 正好是这个格式的地板：它能说出的最狠的话，偏偏用在最安静的一周上。
   改成只给方向（「近期更活跃 / 近期更安静 / 节奏正常」），不再假装有精度。
   **顺带记一个没动的算法问题**：`recent7dMsgs`（:385）是"只要这个会话最后一条消息在
   7 天内，就把它的**全部**消息数加进来"，所以它根本不是"近 7 天的消息数"，
   那句话里的"近期"是界面替算法许的愿。要修得先定"近期"按天直方图还是按会话窗口算，
   已另开任务，不在像素轮里顺手改。
2. **「承诺履约 100%」+ 绿点，底下「0 已完成 / 0 已到期」**。0/0 被算成满分，等于给
   从没做过承诺的人发了个满分。现在分母为 0 时显示「—」+「还没有承诺记录」+ 中性灰点
   （`commitmentKPI`）。这和 §78 的 VIP 判决、以及 `boundaryScore` 在 `workCount == 0`
   时直接给 100 是同一种错：**空分母不是好消息，是没有测量**。
3. **「趋势指标」摘要行的「边界分 70」**：`boundaryScore = 100 - 下班后工作消息/工作消息`，
   即"70"要读者自己做一次减法才知道是"30% 的工作消息落在下班后"。抽成
   `GlobalOverview.boundarySummary`（一处措辞，总览两处 + Markdown 导出共用），
   展开面板里那个圆环也一起改：以前**环的填充度是"分数越高越好"，环下面的文字却在数
   下班后消息条数（越多越坏）**，同一张卡上两个方向相反的读数；现在环、中心百分比、
   「41 / 96 条在下班后」说的是同一个量，颜色分界沿用原来的 30%/60%。
4. **「关系分布」折叠行写着「主要对象 — · 最多 —」**：两个标签配两个占位符 = 零信息。
   两个都缺时改说「消息还不够分出主次」。

验证：`swift test --filter ChatInsightEngineTests|InsightRadarTests|ChromeMotionHygieneTests|HistoricalInsightReliabilityTests`
→ 50 条 0 失败；`swift build` 无警告。像素证据 `r16-kpi-workspace-auto.png`
（1180pt，展开全部模块，滚动 900pt）。

## 82. 滚动开关先证伪了自己，顺便量出"哪些页其实没有下半页"

拿 `--preview-scroll=900` 扫 6 个工作台页面，json 一律回报 `achievedOffset: 900`——
看起来六页都滚了。把 `relationshipRadar` 那张打开一看：**页面纹丝不动**，页头还在顶上。
`clip.scroll(to:)` 允许你滚到文档末尾之外，`bounds.origin.y` 也就照实写 900，
可内容根本没地方去。也就是说这个数**什么都没证明**。

补上真正有信息量的三项（`PreviewRuntime.swift` 的 scroll override）：`maxOffset`
（= 文档高 − 视口高）、`effectiveOffset`（= min(requested, maxOffset)）、
`nothingBelowFold`。重扫一遍，结论反而省了后面的活：

| 页面 | 文档高 | 视口高 | 可滚 |
| --- | --- | --- | --- |
| today | 684 | 691 | 0 |
| tasks | 714 | 934 | 0 |
| commitments | 382 | 611 | 0 |
| drafts | 244 | 623 | 0 |
| dailyReport | 534 | 1017 | 0 |
| relationshipRadar | 714 | 934 | 0 |
| insight（全展开） | 2360 | 671 | **1688** |

前六页在预览数据下**没有下半页**，所以前 16 轮那些"只拍页首"的截图对它们就是全量覆盖，
不是漏看。（真实数据量大时这些页是列表，会滚动——但那是数据撑出来的，不是藏起来的界面。）
唯一有隐藏区域的是洞察总览，于是本轮只对它继续往下拍。

## 83. 洞察总览下半页：第一次进像素又是四处

`r17-insight-s1300.png` / `r17-insight-s1750.png`（展开全部模块）。

1. **「关系分布」展开后只剩两个光杆表头**「层级」「角色」，下面空着。两张表都是先画列头
   再画行，数据为空时列头照样占位——空表里唯一还霸着屏幕的就是表头。改成各自
   `if !isEmpty` 再渲染。
2. **「工作 / 生活」的 0 行**：工作 138、生活 0、其他 0，三行等高，后两行是一条空轨道
   加一个「0」。按"过滤不携带信息的行"删掉 0 行；折叠行的摘要同步，不再写「生活 0%」。
3. **「压力信号」同一屏两套词表**：折叠写「待办 3 · 紧急 1 · 撤回 2」，展开写
   「3 待处理请求 / 1 紧急请求 / 2 撤回消息」。三个数一模一样、名词换了一套，
   而且「待办」和左侧那个真的叫「待办」的页面撞名。统一成展开侧的完整名词。
4. **记一笔没改的**：「最活跃聊天 · 按消息量 TOP 5」实际只有 2 条。标签承诺的是上限不是
   数量，读起来像缺了 3 条。要么改成「最活跃聊天」不带数，要么不足 5 条时不写 5——
   属于措辞策略，留给下轮和 §81 剩下的那条一起定。

（另外看到但确认**没问题**的：时间节奏的小时柱状图 + 图例带计数、周分布柱状图、
最活跃聊天两行的「8人参与 · 平均回复 40分钟」，以及 §81 改过的环与
「42 / 138 条在下班后」在同一张卡上方向一致。）

## 84. 本轮验证

- 全量 `swift test`：XCTest **1833 条 / 15 skip / 0 失败**，swift-testing 70 条全过。
- 改动集中在 `InsightOverviewDashboard.swift`（空表头、0 行、词表统一）与
  `PreviewRuntime.swift`（滚动量具补 `maxOffset` / `effectiveOffset` / `nothingBelowFold`）。
  都是"空数据下的呈现"，行为测试测不到像素，证据是
  `r17-insight-s1300.png`、`r17-insight-s1750.png` 两张前后对照。
- 待办不变：#5（剩余模块的算法↔承诺一致性）、#9（`recent7dMsgs` 的"近期"口径）。

## 85. 无障碍三档：全仓零证据，一查就中

翻遍 17 轮记录：**`--preview-large-type` / `--preview-contrast` / `--preview-no-color`
三个开关一个像素证据都没有**（`docs/qa/2026-09-18-island-pixel/` 里没有任何
contrast/large/no-color 命名的文件）。补拍 9 张（三档 × 岛 compact / 岛详情 / 今日页）。

**第一手证据就是 md5**：`r18-contrast-island-island.png`、`r18-no-color-island-island.png`
和 12 轮的基线 `r12-row-island-inbox-closed.png` **三个 md5 完全相同**
（`283ed1b6…`）。也就是说这两档开关对岛**什么都没做**。往下查：
`CompanionAccessibility.differentiateWithoutColor` 全仓只有 **1 个消费者**
（`CompanionMaterial.swift:729` 的 disc/ring/diamond 轮廓），
`increaseContrast` **0 个消费者**。

### 岛把优先级只画成颜色，而轮廓语言早就存在

`PriorityPulseDot`（`InboxRowView.swift:443`）是 `Circle().fill(color)`——
P0/P1/P2 全靠色相区分，正是「不同颜色也能区分」这个系统开关要求软件放弃的那根线索；
而 app 自己已经有 disc / ring / diamond 一套轮廓词汇，只是没接到岛的点上。

补上：`PriorityPulseDot` 收 `level: InboxPriority`，在该开关打开时
P0→diamond、P1→ring、P2→disc，同一 8pt 占位、同一 14×14 槽位（不动布局，
不碰 §里那条"帧动画不许改变布局"的教训）。

证明它真的到了像素：展开行截图 `--preview-no-color` 与不带的 md5 分开
（`38e3299…` vs `5f56529…`），`r18-nocolor-row-expanded.png` 左上角那颗就是菱形。
`swift test --filter "Inbox|CompanionAccessibility|Island"` → 245 条 0 失败。

### 大字号：收件箱会长，岛的详情页不会

`.dynamicTypeSize(CompanionTypeScale.appliedRange(...))` 挂在 `HUDRootView.swift:170`，
所以展开收件箱确实会放大（512px → 600px 高）。但 `r18-large-type-detail-island.png`
与常规尺寸的 `r14-detail-island-auto.png` **逐像素相同**：`ConversationDetailView`
整页用 `.font(.system(size: 13))` 这类硬编码字号，而 `dynamicTypeSize` 对硬编码字号
**不起作用**。这是本轮最大的一条未修项——它不是一个文件的事（该视图里约 20 处字号），
半改会让同一页有的放大有的不放大，比全不改更糟。另开任务。

### 浅色模式：顺手补上第一份证据

`--preview-light` 拍 今日 / 聊天回顾：语义色自适应正常，对比度可读，
§81/§83 改的 KPI 与卡片在浅色下同样成立（`r18-light-today.png`、
`r18-light-insight.png`）。顺带证伪一个看着像缺陷的东西：今日页「接下来」里的
「2026年9月18日 3:51」不像 24 小时制——查 `Models.swift:209` 是 `HH:mm`，
而这次运行本身就在本机 04:51，3:51 / 5:51 都是真值。**先证伪再改**这条又救了一次。

## 86. 收线：覆盖账与未完项（第 18 轮交接）

证据目录 `2026-09-18-island-pixel/` 共 **678 张 PNG**；预览开关 **24 个**。

**已逐像素过完（含每轮的开关组合）**

- 岛：compact 药丸、peek（mid-dwell）、extended 收件箱、行展开 + ActionPanel、
  **详情态 `.detail`**、通知横幅；动画走 `--preview-transitions` / `--preview-peek` 的
  JSON 轨迹与 `IslandSpringCadenceTests` 离线重放（§66、§71、§11-13）。
- 工作台 18 页 × 视口，加洞察总览的下半页（§82-§83）；其余 6 页经 `maxOffset` 实测
  **没有下半页**，页首即全量。
- 设置 9 分区；窄窗 = 900pt 下限（§77）；浅色模式首份证据（§85）；
  无障碍三档中「不用颜色区分」已生效，「提高对比度」仍空转。

**明确未完（按可操作性排序）**

1. **任务 #10**：岛详情态整页硬编码字号，大字号下逐像素不变（`r18-large-type-detail-island.png`
   与 `r14-detail-island-auto.png` 相同）。约 20 处，需整页一次改到 `WorkspaceType` /
   `companionFont`，半改更糟。
2. **任务 #11**：`CompanionAccessibility.increaseContrast` 全仓 0 消费者 ——
   开关与设置页「模拟提高对比度」按钮都是空转。要么接到那些 `white.opacity(0.35~0.6)`
   的低对比文字上，要么连按钮一起删。
3. **任务 #9**：`recent7dMsgs` 的"近期"不是近 7 天（`ChatInsightEngine.swift:385`），
   文案已先降级成只给方向，算法口径待定。
4. **任务 #5**：剩余模块的算法↔承诺一致性仍在进行；本轮新发现未修的措辞承诺是
   「最活跃聊天 · 按消息量 TOP 5」在只有 2 条时仍写 5（§83）。
5. 证据目录 678 张、62 MB 量级，需要一次按轮归档/清理（**未动**，等用户定）。

本轮之后没有半成品在飞：所有改动都已编译、被过滤测试或像素覆盖，工作树未提交。

## 87. 「按时间回顾」窗口：截图通路 + 第一张像素

`captureSurfaces` 只认三种窗口（`FloatingPanel` / `identifier == "onboarding"` /
标题 == brandName），而回顾窗口的标题是 `CompanionProductCopy.timeReview`
（`RetrospectiveWindowManager.swift:32`）——**四个分支都不命中，所以它从来没被拍过**。
补一个命名分支 + `--preview-retrospective`（该窗口只能从菜单栏或今日页快捷入口打开，
之前不移动指针就到不了）。首张：`r19-retrospective-auto.png`（600×946pt）。

第一眼四处（**本轮只落了通路，缺陷未改**，理由见末尾）：

1. **同一个动作两个按钮、两个名字**：页眉「↻ 重新生成」与空态卡里「✦ 生成本次回顾」
   都调 `runJob()`（`RetrospectiveTabView.swift:65` 与 `:117`），而且都是
   `.borderedProminent` + `.tint(.cyan)` —— 同形状同权重。空态下「重新生成」还名不副实
   （没有可"再"生成的东西）。按「重复控件只留一个，留贴着作用对象的那个」应留卡内那颗、
   空态时隐藏页眉那颗。**没改的原因**：页眉与空态是两个独立 computed view，隐藏条件在
   `:35` 那个 `if` 里，本轮剩余预算不足以确认该条件后安全落刀；宁可不改，也不凭猜
   动控件拓扑。
2. **空态卡约 900pt 高，内容只占上面 150pt**：卡片没有随内容收。
3. **空态图标是 `chart.line.uptrend.xyaxis`（趋势上升）**：那是"有结果"的语义，
   用在"还没有结果"上。
4. 页眉右上角灰字「WeChatHUD」对比度低（`.white.opacity` 一档），且与窗口标题重复。

## §88（第 20 轮）§87 的四条：落了三条，一条留在原地

隐藏条件读到了：`body` 的 `if let run = latestRun { … } else if !isRunning { emptyState }`
（`RetrospectiveTabView.swift:32-36`）。所以空态与结果态互斥，页眉那颗按钮在
`latestRun == nil` 时是纯冗余 —— 于是这一刀可以凭条件落，不用凭猜。

**已改（`Sources/WeChatHUD/Views/Retrospective/RetrospectiveTabView.swift`）**

1. 页眉按钮包进 `if latestRun != nil`。空态下只剩卡内「✦ 生成本次回顾」一颗 CTA；
   有结果后「↻ 重新生成」回到它该在的位置 —— 页眉，因为它的作用对象变成了整页。
2. 空态卡去掉 `maxHeight: .infinity`，卡片按内容收。窗口从 946pt 高缩到 796pt，
   截图里那片空框没了。
3. 图标 `chart.line.uptrend.xyaxis` → `clock.arrow.circlepath`。上升折线是"有数据"
   的语义，放在"还没有结果"上等于让空态吹牛；回看时钟才是这个页面在做的事。
   同时删掉文案里「点"重新生成"后，」这半句 —— 它指的那颗按钮刚刚被我隐藏了，
   留着就是一句指向不存在控件的说明书。

**证据**：`r20-retrospective-auto.png`（1200×1592 px）对 `r19-retrospective-auto.png`
（1200×1892 px）；高度差 300px 就是第 2 条。`swift test --filter Retrospective`
→ 25 tests / 4 suites passed，exit 0。改前 grep 过「重新生成 / 生成本次回顾 /
还没有回顾结果」，测试与快照断言里零命中，所以这不是把断言改绿。

**没改的第 4 条**：页眉右上角灰字「WeChatHUD」。它在 `RetrospectiveWindow.swift`
的窗口装配层，不在这一页里；本轮预算只够改一个文件，宁可把三条坐实在已有截图上，
也不在最后一轮跨层动窗口 chrome。

**仍记录在案**：窗口内容止于约 530pt，下面还有约 270pt 纯背景 —— 空态本身不需要
796pt 高。这属于窗口默认尺寸策略，和 §87 第 2 条是同一类毛病的另一半。

## §89（第 21 轮）撤回一条我自己的结论：任务 #11 是假阳性

§85 记的「`increaseContrast` 全仓 **0 个消费者**」是错的，撤回。

**错在哪**：我只 grep 了符号本身（`CompanionAccessibility.increaseContrast`），
而这个开关是**通过 token 层**被消费的：`hairlineWidth` / `cardEdgeWidth` /
`borderOpacityScale` 三个计算属性读它，视图读那三个 token。真实消费者有
`FirstLaunchContactPicker.swift:120`、`SettingsRow.swift:40`、
`CommitmentTabView.swift:272`、`DiscussionWorkspaceView.swift:627`、
`CompanionMaterial.swift:66/453` —— 5 个文件 6 处。一个只查直接引用的 grep
把一条通了电的线路判成了死线。

**用像素证伪，不是用 grep 反证**：同一屏（工作区总览）跑两遍，只加/不加
`--preview-contrast`，其余 flag 完全一致：

| | 字节 | md5 |
|---|---|---|
| 关 | 1,462,780 | `7195fb73…` |
| 开 | 1,472,190 | `861468ff…` |

两张图不同 ⇒ 开关确实改渲染。`CompanionAccessibilityTests` 里也早有
`cardEdgeWidth` 1 → 1.5 的断言，只是它断的是 token，我找的是符号，两边都没说话。

**留下的那半条（真问题）**：对比度模式只抬**描边**（发丝线 0.5→1、卡片边 1→1.5、
边框不透明度 ×2.4），**不抬文字**。而这一屏里最看不清的恰恰是文字：
`.white.opacity(0.45/0.52/0.56)` 那一整层次级灰字，包括 §87 第 4 条的页眉
「WeChatHUD」。所以准确的表述不是"开关空转"，而是"**开关只管了一半的对比度**"。
补法是在 `CompanionAccessibility` 加一条文字前景 ramp（例如 `opacity < 0.7` 的
次级字统一 ×1.45 封顶 0.92），但它要动的是散落在 Views 里的几十处 `.foregroundColor`，
没有中心 helper 可挂 —— 属于整页重构量级，不在收尾轮开。

**工具故障的处置**：`/tmp/wcsnap.sh` 这轮报 `NO FRESH CAPTURE`，根因没查出来，
不编。本轮改用等价的内联脚本（等 `wechathud-capture-done` 哨兵、而不是等"文件数稳定"），
两次跑图都正常。wcsnap 里那套"稳定计数"等待逻辑是待修项。

## §90（第 22 轮）把对比度模式的另一半补上：文字前景（任务 #13）

§89 说这一档"只管描边、不管文字"。本轮补上文字那一半。

**范围实测比预估小得多**：全仓 `foregroundColor(.white.opacity(...))` 只有 **35 处、
3 个文件** —— `ConversationDetailView`（岛详情态）15 处、`RetrospectiveTabView` 18 处、
`RetrospectiveWindow` 2 处。其余界面用 `.secondary` 等语义色，本来就走系统对比度。
也就是说这不是"整页重构量级"，是两处暗底面板的局部病。

**地板是算出来的，不是拍的**：`Color.white.opacity(a)` 合成到近黑画布上，
对画布取 6 % 白（面板自身 `black.opacity(0.94…0.96)` 之外的最诚实估计），
按 WCAG 的 sRGB 线性化算对比度：

| 名义不透明度 | 改前对比度 | 改后（开关开） |
|---|---|---|
| 0.30 | 3.3:1 | 0.52 → 5.2:1 |
| 0.35 | **2.7:1** | 0.52 → 5.2:1 |
| 0.45 | 4.0:1 | 0.61 → 6.4:1 |
| 0.56 | 6.1:1 | 0.76 → 8.6:1 |
| 0.88+ | 不变（正文/标题已经够响，再抬会把层级压平） |

4.5:1 是正文的 AA 线，反解出"至少 a≈0.50"，所以 `legibleDimFloor = 0.52`。
岛详情态里最惨的 0.35 那档（页眉灰字「WeChatHUD」，即 §87 第 4 条）实测 2.7:1 ——
它一直是读不清的，不是感觉问题。

**接法**：`companionDimmedForeground(_:)` 是个 `ViewModifier` 而不是裸调用，
因为它必须读 `companionDisplayGeneration` —— 这些 ramp 是 static 读数，SwiftUI 只对
"读过的东西"建立依赖，不读代次的话用户拨开关不会重绘。同时给回顾窗口补了代次发布：
它是第三个根，岛和工作台都发了，它没发，开关拨到那儿就断。

**测试**（`CompanionAccessibilityTests`，11 项全绿）：源码扫描式门禁 —— 从
`Sources/` 里抓出所有 `companionDimmedForeground(数字)` 字面量，逐个在开关打开时
断言 ≥4.5:1；并断言扫到 ≥20 处，防止扫描本身坏掉造成"空跑通过"。
**变异检验做过**：把地板从公式里拿掉，测试立刻报
`ConversationDetailView.swift's 0.3 caption lifts to 0.405 … still 3.9:1`。
这个检验还顺手抓出公式自身一个 bug：只有封顶没有兜底时，0.87 会被**调暗**成 0.86，
于是外层加了 `max(nominal, lifted)` —— 一个可读性开关不许让任何东西更难读。

**像素证据**（逐像素差分，不靠肉眼）：
- 岛详情态：变化 4,230 像素，**4,230 变亮 / 0 变暗**，覆盖 8 个行带，平均提亮 0.078。
- 回顾窗口：变化 17,128 像素，17,095 变亮 / 33 变暗（字形抗锯齿边缘），平均提亮 0.128。
- 说明文字所在横条（y=380..440）meanLum 0.120 → 0.144。

**一次必须先证伪的"假回归"**：默认态（开关关）的新截图与改动前基线 md5 不同，
颜色数 49 → 29。同一颗二进制、零代码改动连跑两次，得到两个不同 md5，
而其中一个**正好等于**改动前的基线哈希 `309a21a2…`。抖动来自窗口焦点态
（激活/未激活的交通灯按钮颜色），不是这次改动。 ⇒ 对渲染实时数据 + 系统 chrome 的
表面，跨时间比 md5 不是有效判据；有效的判据是"新二进制能复现旧哈希"，加上
单元测试里那条"开关关时逐值恒等"。

**验证**：`swift test --filter "Accessibility|ChromeMotionHygiene|Retrospective"`
→ XCTest 42 项 / swift-testing 25 项，0 失败。改动未提交。

## §91（第 23 轮）岛族整片接上 Dynamic Type（任务 #10）

§84 像素证明过：岛详情态在「大字号」下与默认**逐字节相同** —— 一个承载整段文字的页面
完全不理会系统的文字大小。本轮收掉。

**接法**：机制早就有（`companionFont(size:weight:)` → 按 `CompanionTypeScale.factor`
缩放，10pt 兜底），只是岛详情态 24 处全用了裸 `.font(.system(size:))` 绕过它。
24/24 换成 `companionFont`。

**岛族剩下的 24 处不是一刀切**：逐个看语境后，绝大多数是 `Image(systemName:)` 的字形
（xmark / chevron / gearshape / 三角警示），它们跟的是**固定尺寸的容器**，不是文字 ——
放大到 1.48× 会顶破按钮的圆形命中区。真正是文字的只有 3 处，一并接上：
`DetailPanelView` 缺会话页的标题与说明、`InboxView` 底部动作条的文字标签、
`CompactInboxBar` 的未读数字。图标保持设计尺寸是有意的，不是漏掉。

**证据**
- 默认态：岛详情截图 md5 `a16644f3…` 与改动前**完全相同**（`.large` 因子 1.0），
  没碰开关的用户一个像素都没变。
- 大字号：同一页变化 150,873 像素、覆盖 30 个行带（改动前是 0 —— 那就是缺陷本身）。
  目视：气泡随行增高、页眉与三颗按钮不裁切。
- 底部动作条「待办 / 查看全部」在大字号下完整可读（`r22-inbox-row-expanded-large-type.png`）。

**新增 `IslandTypeScaleTests`（4 项）**：不用算术而用真实渲染量墨迹包围盒 ——
① 未读徽章在最大档确实长高；② 长高后仍在紧凑条 32pt 内、且不超过左翼 56pt
（预算从 `FloatingPanel.swift` 的 `contentRect` 现场解析，不让测试和实现各写一个数）；
③ 岛详情态不许再出现裸 `.font(.system(size:`；④ 一条**被自己数据推翻后改写的断言**：
我原先写"超过上限一档就会顶破紧凑条"来为 `.accessibility2` 封顶辩护，实测 accessibility3
的徽章墨迹只有 14pt，离 32pt 很远 —— 紧凑条**不是**封顶的理由，两栏工作台页才是
（`CompanionTypeScale.range` 的注释本来就是这么写的）。断言改成记录这份余量，
不留一条错误的理由。

**一个复发的坑**：`--preview-expand-row` 是两段序列，哨兵在第一张就写；用
`ls ...(N)` 之类带 glob 的条件等第二张，zsh 在无匹配时会让整个条件失败，
循环第一秒就退出、应用在 3 秒时被杀 —— 于是拿到一张**动画未停稳**的图
（第一行标题被切一半、底部大片空）。这张图不能当证据。改成固定等待后正常。
判据：多段序列的每张图都要单独确认"已停稳"，不能假定序列后段一定完整。

## §92（第 24 轮）洞察算法两处：「近期」根本不是近七天，多分片库只算最后一个分片

任务 #9 起于"口径不清"，查下去是两处算错，其中一处影响面极大。

### 一、`bulkMessageStats` 逐库赋值，不跨分片归并（P1）

`WeChatReader.bulkMessageStats` 外层 `for relPath in findMessageDBs()`，内层
`result[chatUsername] = BulkChatStats(...)` —— **直接覆盖**。同一个 `Msg_<md5>`
表合法地存在于多个 `message_N.db`，于是每次洞察扫描后，一个对话的统计只剩
**最后读到的那个分片**。

影响面不是我猜的：`WeChatShardMergeTests` 的文件头记着参考账号实测
**932/2572 张表跨分片、115 个关注对话里 103 个是多分片** —— 约九成对话的
「消息总量 / 活跃对话 / 非工时占比 / 密度」全部只反映一部分历史。
读消息那条链路早就修过（`getMessages` 会归并），统计这条漏了，所以它只在
"数字看着挺合理"的层面暴露不了 —— 渲染质检抓不到，只有算法审计能抓到。

修法：`BulkChatStats.merged(with:)` 折叠 totalCount/selfCount/senderCounts/
hourly/weekday/typeCounts/earliest/latest/recentCount；`selfInitiated`（"谁先开口"）
取**持有最早消息的那个分片**，而不是读取顺序的最后一个 —— 折叠顺序不该改变答案。

### 二、`recent7dMsgs` 数的是"最近活跃的对话的全部历史"

原式：`if s.latestTs >= sevenDaysAgo { total += s.messageCount }`。一个 30 天窗口里
只要某对话最近 7 天说过一句话，它**整段 30 天**的消息都被算成"近期"。再除以 7 得到
"近期日均"，与"全窗口日均"（total/30）相除 —— 只要所有对话都近期活跃（正常账号基本如此），
比值恒等于 **30/7 ≈ 4.3**，与那一周实际忙不忙无关。界面据此常年显示「近期更活跃」+ 橙色点，
说的其实是"你选的时间范围是 30 天"。

修法：让"近期"回到**一段区间**。SQL 扫描处已有逐条 `create_time`，直接数进
`recentCount`；口径常量收进 `InsightRecentWindow`（7 天），扫描与除法共用一处定义 ——
"cutoff 在一处算、`/7` 在另一处写"正是这类指标悄悄跑偏的方式。
另外：窗口 ≤7 天时"近期"与"全期"是同一段，比值按构造必为 1.0，这不是"节奏正常"而是
**没有可比性**，`recentDensityRatio` 改为 `Double?`，卡片显示
「时间范围不足 7 天，无法比较近期与整体」+ 中性色（沿用本轮已确立的"空分母不许打分"）。

### 测试与变异检验

`InsightDensityAndShardTests`（6 项）+ `WeChatShardMergeTests` 新增 1 项：
- 均匀历史 → 比值 1.0（旧式给 4.3）；安静周 → 0；忙周 → 4.29；窗口 7 天 → nil。
- 用**现成的多分片合成库**测真实调用点（不是只测 `merged(with:)` 这个纯函数）：
  两分片各 2 条 → 期望 4 条。
- 变异检验：把归并退回成 `result[chatUsername] = shard`，该测试立刻报
  `("Optional(2)") is not equal to ("Optional(4)")` —— 门禁是真的在守。

### 没做到的

KPI 卡片的**视口证据这轮没拿到**：`--preview-insight-overview` 那一跑截到的是
「今天」页与设置窗口（窗口宽度还带着上一轮 `--preview-narrow` 的 autosave 残留，
2830×1868 px），洞察总览没渲染出来。文案与配色分支是 `recentDensityRatio` 的纯映射，
由上述测试覆盖，但"这张卡在真机上到底长什么样"仍是未验证项，不留作已完成。

## §93（第 25 轮）主动提醒四条规则的"界面承诺 vs 算法"审计（任务 #5）

派了一个代理做跨文件比对（只读代码与文案，不碰任何聊天原文），报回 8 条。
**按本轮定下的规矩，代理说的只是它打算做什么** —— 所以逐条自己回源码验，
验实 6 条、撤回 0 条、修掉最重的 1 条，其余建任务。

### 已修（P0）：静音的人，承诺到期照样弹

- 界面（`AdmissionSettingsView.swift:626`）：「不想再看到谁的消息」
  ——「选谁，就哪个对话都不再提醒——包括他所在的群。」
- 代码（`ProactiveAlertEngine.evaluateCommitmentDeadlines`）：只遍历 commitments，
  **一次静音名单都没读**；调用点（`ChatMonitor.swift:535-536`）也是从库里直接捞
  pending + overdue，没有过滤。扫描那条链路是通过 `AdmissionPolicy.isMuted` 认这份
  名单的，唯独提醒这条不认。结果：你把某人彻底静音了，他欠你的承诺一到点，
  通知中心照样弹「承诺已到期」。

修法不是新造一套判据，而是把**同一份**名单接进来：`store.loadGlobalIgnoredSenders()`
+ `store.loadIgnoredSenderMap()`（正是 `AdmissionPolicy` 的两个来源），
按 `HUDStore.senderIdentifier` 匹配。承诺只存了对方显示名（`Commitment.commitTo`），
所以按 name 标识匹配，会话级静音再按 `chatUsername` 查一层。

测试（`ProactiveAlertTests` 新增 2 项，26/26 绿）：全局静音 → 不弹；
**对照组**同引擎换个没静音的名字 → 照弹（证明"不弹"是闸门在起作用，不是夹具坏了）；
会话级静音只静音那个会话，另一个会话仍弹。
变异检验：把 `guard !isMutedForCommitment(...)` 换成 `guard true`，
立刻报 `("["承诺已到期", "承诺已到期"]") is not equal to ("["承诺已到期"]")`。

### 已核实、建任务未修（按严重度）

- **#15 P1**（下一轮自查后撤回，判据与触发器见 §94 之后的 §95）：右键菜单「隐藏这条更新」是单条语义，`dismissInboxItem:2610` 写的却是
  `store.silenceChat(chatUsername:silencedAt:)` —— 会话级水印。点掉一条，同会话里
  时间戳不晚于它的所有消息一起消失，且没有任何提示。（自己读过两处源码确认）
- **#16 P1**（下一轮已收口，见 §94）：README:135 列的「多条未回」对**私聊不可达**。规则 3 数 `unreadItems`
  行数（≥3），而 `ScanEngine.swift:185-190` 对非群聊只取
  `recentMsgs.first(where: !isFromSelf)` —— 一个私聊永远只贡献 1 行。
  三条未回私聊 = 1 行 = 永不触发。（自己读过确认）
- **#17 P1**（下一轮拆成两半：前半撤回，后半已修，见 §96）：通知设置三颗「弹出」开关的消费者只有浮窗路径
  （`ScanEngine:610-611`、`AppDelegate:593`），引擎从不读 `NotificationConfig`；
  三颗全关，紧急待回复（且不占每小时预算）/多条未回/VIP 升档/跨群 VIP 照样进通知中心，
  而文案写的是「关掉只是不弹」。同一条里还有「已安排在X提醒」：所有
  `UNNotificationRequest` 都是 `trigger: nil`，没有任何东西被排期。
- **#3/#7/#8 P1–P2**：「他们一开口就提醒你」受另一页开关控制；「已超时未回复」
  写死 30 分钟而用户可在别处自定义；`MacExperienceSettingsView:163-171` 等三处死文案。

### 顺带证实的一条好话

AGENTS.md 说的「VIP 升档 1h 档只有视觉提示不发系统通知」**是真的**：
`pushEscalationAlert` 的 t2 分支被跳过（`:237-243`），与
`CompanionProductCopy:136-140` 一致。不是所有承诺都落空，这条记下来。

## §94（第 26 轮）收口 §93 的 #16：私聊连发以前根本触发不了「多条未回」

### 先复现，再动手

§93 里那条"读源码确认过"的判断需要一个能跑的证。`SyntheticShardedScanFixture`
能造出真加密的微信库，于是直接驱动真链路 `ScanEngine.performScan`：
私聊 5 条入站（senderId 1=对方）、`unreadCount: 5` → 结果 `unreadItems` 里
**只有 1 行**。规则 3 的桶 `+= 1`，阈值 `>= 3`，所以这条 README 上写给客户的能力
对私聊是结构性不可达的 —— 一个人连发 5 条 DM 永远不弹，只有群成员能弹。

不是"阈值定高了"，是**计数单位错了**：私聊一行代表的是整段未回尾巴，
群聊一行代表一条消息。同一个桶里混两种单位。

### 改法：让行自己说它代表几条

- `UnreadItem.unansweredInboundCount`：私聊行 = 我方最后一条之后到达的入站条数；
  群聊行 = 1。字段**故意不给默认值**（`let` 带初值时 Swift 的成员初始化器
  仍要求显式传参，试过 `var … = 1` 会让单位问题在新增构造点悄悄回来）——
  新增构造点必须回答"我这一行代表几条"，这正是这个字段存在的理由。
- `UnreadItem.inboundMessageCount = max(1, unansweredInboundCount)`：
  所有"按条计"的地方共用它，规则 3 和日报不可能各说各话。
  `max(1, …)` 不是凑数：已回的行还在屏上时，它至少代表它显示的那一条。
- 单位收口顺带把日报的另一处一起修了：`totalUnread` 之前是
  `私聊按对话数 + 群聊按条数`，而这个数最终写成 `未读 N 条`
  （`DailyReportBuilder:346`）/`unreadMessageCount` 进 AI 提示词。
  现在三项都是条数，`recomputeStatsFromItems` 跟着一起改 ——
  那处注释本来就要求两边同单位，否则会漂。

### 与既有实现的关系（不是重复造）

`ReplyDebtScorer` 早就有 `inboundCountSinceLastOutbound`，同一个想法的按会话版本，
连文案都在说「连续未回复 N 条」。没有直接复用它，因为它的桶是**会话**、
且已经剔掉静音的人；规则 3 要的是**人**（同一人在一个私聊 + 两个群里发言要合起来看）。
两边口径一致：都是"我方最后一条之后"，且都和 `replied` 用同一个
`> latestSelfTime` 比较，保证 `replied ⇒ 计数 0` 这个不变量不会被打断。

### 测试与变异检验

新增 `PrivateBurstCountTests`（8 项）：链路上 3 项走真 `performScan`
（5 条折成 1 行且携带 5、我方回复把尾巴切成 2、已回的是 0 但屏上仍算 1），
规则侧 4 项走真 `ProactiveAlertEngine.evaluate`（1 行 3 条要弹、1 行 2 条不弹、
已回的 9 条不能把 2 条抬成 11 条、群聊行仍按 1 计），加 1 项单位定义本身。

- 变异 A：ScanEngine 的 `unansweredInboundCount:` 改回 `1` → 3 项链路上报红，
  含 `("Optional(1)") is not equal to ("Optional(5)")`。
- 变异 B：规则里 `item.inboundMessageCount` 改回 `1` → `testThreeUnanswered…`
  三连红（0≠1、nil≠"多条未回"）。
- 相关面回归 146 项绿（ProactiveAlert / W5 / ScanEngine* / ScanBacklog /
  AnsweredFeedEviction / InboxActionPersistence / DailyReportBuilder /
  GroupWindow / RecallContext / InboxViewLogic / InboxBuilder）。

### 留在原地的（本轮判过，不做）

收件箱那一行现在**知道**自己代表 5 条，但界面上仍只显示最新那条的文字。
要不要给它一个「5 条」的小角标，是把 `UnreadItem` 的口径接到 `InboxItem`
（要过 `InboxBuilder`）的产品选项，不是正确性缺口 —— 微信自己的会话列表
也是一行一对话。撤销路径：`unansweredInboundCount` 已经在链路上，加角标只是读它。

## §95（第 26 轮）撤回 §93 的 #15：「隐藏这条更新」没有抹掉别的消息

`dismissInboxItem:2614` 写的是会话级水印（`store.silenceChat(chatUsername:silencedAt:)`），
这一点 §93 记得没错。但由它推出来的"点掉一条，同会话里其他消息一起消失，且没有提示"
是错的 —— 我没有先看水印作用在哪个表面上。三条证据：

1. **收件箱一行就是一个对话**：`InboxBuilder.build` 用 `seen: Set<String>` 按
   `chatUsername` 去重（债务项优先，通知项 `guard !seen.contains`）。同一会话根本
   不存在"另一行"可被抹掉。所以「隐藏这条更新」和它的粒度是一致的。
2. **水印的另一半作用面没有 View 消费者**：`silencedAt` 还在
   `ScanEngine:214/238` 抑制 `unreadItems`，而 `unreadItems` 的消费者只有
   `ProactiveAlertEngine.evaluate` 与 `recomputeStatsFromItems`（全仓 grep 无任何 View 读它）。
   也就是说被水印压掉的那部分只影响"还要不要提醒"，而"我处理过了别再提醒"正是点它的意图。
3. **不是无提示、也不是不可逆**：`dismissedInbox` 命中的行进 `handled`，
   收件箱渲染 `已处理 (N)` 页脚（`InboxView:475`）、行上有「恢复显示」（`:520` →
   `restoreInboxItem`），今日页还有「撤销」（`AssistantTodayView:231`）。

### 这条为什么值得写下来（触发器）

判断本身是可复用的：**看到"作用域比文案宽"的水印，先问它作用的那个表面有没有
更细的粒度可失去**。收件箱按对话去重，所以会话级水印无损；
而 §94 刚给 `UnreadItem` 加了"一行代表几条"，如果哪天收件箱改成一条消息一行
（每消息一行会更像微信聊天列表），这个水印就会真的开始一次点掉一片 ——
到那时 #15 从假阳性变成真 bug，修法是把水印从 `chatUsername` 键改成
`(chatUsername, senderIdentifier)` 或按消息 id 存集合（需要先给行一个稳定 id）。

## §96（第 27 轮）#17 拆成两半：一半是假阳性，一半是真的空承诺

### 先撤回一半

§93 记的「三颗『弹出』开关关不掉系统提醒」，读源码复核后**不成立**：

- 这三颗的消费者是 `NotificationConfig.shouldPresent`，落在 `AppDelegate:593`
  （`panelState.showNotification`）与 `ScanEngine:630`（是否进通知面），
  管的是**浮窗**；主动提醒四条规则走的是另一条路
  （`ProactiveAlertEngine.systemNotificationSender` → `UNUserNotificationCenter`）。
  两条路本来就不是一个开关能关的。
- 而且这页**自己就声明了作用域**：页面副标题是「只管顶部浮窗」
  （`SettingsView:87`）。所以这不是"文案与副作用不符"，是我没看页头就下了判断。

### 真的那一半：「已安排在X 提醒」什么都没排

`snoozeReceipt`（`CompanionProductCopy:109`）在四个生产表面上挂着
（收件箱撤销条 ×2、横幅 toast、今日页回执卡），文案承诺"在某个时间点提醒"。
全仓只有两处构造 `UNNotificationRequest`，两处都是 `trigger: nil`
（`ProactiveAlertEngine:408`、`AutopilotService:1902`）—— **没有任何东西被排期**。
到点后真实发生的是：水印过期 → 下一次心跳扫描把行放回收件箱。

改成说这件事：「\(clockLabel) 后回到收件箱」。刻意不写"1 分钟内"：
`safetyScanInterval` 默认 60 秒，但它是 `max(10, syncCfg.intervalSeconds)`
算出来的用户可配置值，写死数字就是下一个假话。

### 顺手把作用域那行补齐（并给它上一道防漂闸门）

页脚原来只写「承诺到期等系统通知由 macOS 通知设置管理」——"等"字掩盖了
另外三类同样关不掉的系统通知。现在按引擎真能发出的标题族列全：
VIP / 承诺 / 多条未回 / 紧急待回复。
`testNotificationSettingsScopeLineCoversEveryAlertTitle` 扫
`ProactiveAlertEngine.swift` 里 `title: "` / `title = "` 的字面量，
要求每一个都落在这四族里，且页脚逐族点名 —— 以后加第五类规则不改这行就红。
变异检验：把页脚换成「承诺到期等」，三条 `the scope line omits …` 立刻报红。

### 像素质检这一轮真的抓到了东西

`--preview-activate --preview-tab=notifications --preview-capture=9` 拍到的是
**工作台窗口**（`writeSurfaceBitmaps` 按 `window.title == brandName` 认它；
只给 `--preview-tab` 不给 `--preview-activate` 时工作台区不出图，只出 320×32 的岛）。
第一张图上看：页头已经写着「只管顶部浮窗」，而我新加的页脚又以
「这些开关只管浮窗。」开头 —— **同一屏把同一句话说两遍**。删掉重复的前半句，
重拍确认剩下的那句单行不折行、不挤。这就是"检查多余文案"在像素层的样子。

两张图之间还有两处看着像回归的差异（开关轨道由绿变灰、「3 秒」选择器变灰），
是窗口 key/非 key 态的标准渲染，与 §22 那条 md5 抖动同源，不是改动。

### 留在原地的（已定价）

要让「已安排在X提醒」变成真话，得真的排一次提醒。两条路：
① `UNCalendarNotificationRequest` —— 系统代排，但**到点无法复核**：
你早就回过那条消息了，它照样弹，这是拿一个错承诺换另一个错承诺；
② 应用内定时器 + 到点前重扫校验 —— 能做到"只对还没回的提醒"，
代价是 `restoreInboxItem` / 再次 snooze / 静音 / 退出登录四条路径都要撤销排程，
再加一个可注入时钟的测试面。判据：只有当"离开电脑也要被提醒"成为需求时才值。
另一个证据缺口：撤销条/toast 上的回执文案没有预览开关，本轮没截到像素
（改动是 12→13 字符、在带 Spacer 的 HStack 里，布局风险为零）。

## §97（第 27 轮）VIP 升档第一档：把「超时」这个词还给能配置它的那个人

`Models.swift:41-45` 早就写清楚了：升档阶梯是**固定里程碑**，
和 `ReplyDebtConfig` 里那个可按联系人配置的「多久算超时」是两回事
（"changing 「多久算超时」 moves the badges but not the reminders"）。
但 t1 的文案却写着 `title = "VIP 消息超时"` / `body = "…已超时未回复"` ——
于是给某个 VIP 设了 2 小时窗口的用户会看到：收件箱里这条**没有**标超时，
系统通知里它**已经**超时。同一个词，两个意思，两个结论。

算法没错（里程碑本来就该固定），错在文案借了对面的词。改成只说自己知道的事：
t1 = 「VIP 等你 30 分钟了」/「…的消息还没回」，和 t3/t4 的
「等你 2 小时了」「等你 4 小时了」同一个句式；t3 的标题改为从
`tier.agingLabel` 生成（今天输出完全相同，但阶梯一改就不会只改一半）。

顺带同一族的英文单位泄漏：菜单栏 badge 是「3 待办 · 等 4h+」——
一条全中文里嵌着 `4h+`。`agingLabel` 的生产消费者只有
`CompanionProductCopy.menuBarBadge` 一处（全仓 grep 确认），所以直接换成
「30 分钟 / 1 小时 / 2 小时 / 4 小时+」，badge 变「3 待办 · 等 4 小时+」。
`MenuBarController` 里没有截断或宽度上限逻辑，宽度由 NSStatusItem 自管。

测试：`testFirstTierClaimsTheWaitNotATimeout` 钉住 t1 的标题/正文，并断言
这条阶梯发出的任何通知里**不出现**「超时」二字（防以后又借词）。
它自己也先红了一次：`makeUnread(minutesAgo:)` 用的是真实墙上时间，
而引擎注入的 `now` 是 1970 年附近，等待时长算成负数 → 档位 `.none`。
改成显式传 `timestamp: start.addingTimeInterval(-45*60)` 才对。
相关面 184/184 绿，release 零警告。

证据缺口（诚实记录）：菜单栏 badge 不在截图通路里
（`writeSurfaceBitmaps` 只认 FloatingPanel / 工作台 / onboarding / 回顾窗口，
NSStatusItem 不属于任何一支），所以这一处只有单测证据，没有像素。

## §98（第 27 轮）删掉 AIGroupCatchup：每次群 @ 花一次 AI 调用，产出没人读

「每个模块的算法」这一维最后一块。派了代理去画链路，**每条结论自己回源码复核过**：

- `GroupContextBriefing` 上 8 个 `deep*` 字段里，界面只读 `deepSuggestedAction`
  （`InboxRowView:358`）。其余 7 个（background / whatTheyWant / hiddenContext /
  stakeholders / yourPosition / timing / risk）全仓 grep 只有声明和写入，**0 读取者**。
- `AIGroupCatchup.summarize` 在 phase 2 里只写 `deepBackground` 和 `deepWhatTheyWant`
  这两个没人读的字段（`ChatMonitor:682-697`）—— 也就是说这次 AI 调用的全部产出都被丢掉。
  代价是真实的：每条群 @ 简报一次调用（含 `AIGroupCatchup:96-120` 的有界重试），
  而且会把 `sanitizeForAI` 处理过的群聊原文发出去。
- 生产消费者只有 `ChatMonitor`（写死字段）+ `ClassifierCLI` 的 `group-catchup` 子命令
  （调试工具，不是产品面）+ 两个测试。

判据沿用本仓库已经接受过四次的规则：**生产不可达就删，连它自己的测试和 CLI 一起**。
删掉 `AIGroupCatchup.swift`(189 行)、`group_catchup_v1.txt`、`group-catchup` 子命令
（`main.swift` 的列表 + 分发 + 83 行实现）、`ChatMonitor` 的 phase-2 catchup 块、
7 个没人读的 `deep*` 字段与写入、`AIServicesTests` 的两处、
`LiveCompanionAcceptanceTests` 的整段验收与其 `GroupEvidence` 结构。

保留 `ContextAnalyzer` 那一次调用：它的 `suggestedAction` 是行上真看得见的「下一步」。
`GroupContextBriefing: Codable` 是合成实现，删可选字段对旧 JSON 解码安全（未知键被忽略）。

净效果：群 @ 简报的 AI 调用从 3 次（briefing + catchup + analyzer）降到 2 次，
少一份出网的群聊原文，少 219 行没人看的代码。

### 顺带查实并留下的两条（都不是 P0，写清楚不动手）

1. **写作风格承诺成立**：`StyleProfiler` 的画像确实进 prompt
   （`AIReplySuggester:151-153` 的 `[风格参考]`，另有 autopilot 两条链），
   README:139 那句不是空话。缺口是**静默降级**：某会话自己发过的消息 <20 条时
   `buildStyleHint`/`buildRichStyleHint` 双双返回 nil，界面上没有任何地方说明
   "这个会话还没学会你的风格"。
2. **反馈闭环只有一半**：`ai_feedback` 的唯一写入点硬编码 `adopted: true`
   （`ConversationDetailView:363-366`），`ignored_suggestion` 无人写，
   所以 `buildFeedbackHint` 里 `if rejected > 0` 那一支永不触发 —— 模型看到的
   历史永远是"全被采纳"。好消息是它不会因此说谎（条件分支不输出），
   坏消息是"你的反馈会持续打磨建议质量"只对了一半。
   补法要先把"忽略"定义出来（一键采纳只灌输入框、不写反馈，`ActionPanelView:574-583`），
   是一个产品决定而不是一个 bug 修复，留在这里定价。

---

## 第 28 轮：七路并发对抗审计（P0 清零）

方式：同一轮里派 7 个只读子代理，按互不重叠的风险面切分 —— 崩溃/主线程阻塞、
隐私外发、数据正确性与持久化、安全与更新链路、AI 信任边界（自动发送）、
常驻退化（并发与资源增长）、交互安全与不可逆操作。每个代理返回后**逐条回源码复核**
才动手；下面每条都标了"实测方式"，没有一条是按代理的措辞直接改的。

### §99 私聊连发时把抓取窗口当成条数（commit dd4e6e32）

自己引入的缺陷：§94 为了触发「多条未回」让私聊折叠行携带 `unansweredInboundCount`，
但抓取窗口硬编 20。摘到的证据（临时探针跑真合成库）：
`PROBE count=20 stats=20 preview=第 26 条` —— 26 条未回，界面和提醒都会说「有 20 条」。

修法：窗口跟随 `session.unreadCount`（上限收到 `ScanEngine.unreadWindowCap = 60`），
窗口装不下时把数字标成下限（`UnreadItem.unansweredCountIsFloor`），规则 3 文案走
「N 条以上」。变异验证：把 floor 常量写死 false → 3 个新用例红；把窗口退回 20 →
3 处红。

### §100 AI 出网隐私边界：出口才是边界（commit 428b2665）

代理报了 7 条"绕过 `sanitizeForAI` 的裸文本出网"，7 条全部回源码成立：
洞察页把一天最多 500 条消息原文 + 撤回原文 +（senderName 为空时回落的）**wxid**
发出去；自动回复把批量触发消息、会话账本里的双方原话、风格样本发出去；群简报把
同一条消息明文 + 掩码双份发出去；回复建议、撤回分析、日报引用同理。它们的共同点
是只过了 `oneLine`。`AIService.swift` 里那句"每条 live 提示词都过 sanitizeForAI"
是个假前提。

改法照抄本仓已有的判断：注入守卫当年也是逐模板写、漏一个就裸奔，后来收口成
`completeWithMetadata` 里的 `dataBoundaryPreamble` 一行。掩码同理 —— 出口再掩一次
证件/卡号/手机号/邮箱，任何站点漏了都不再等于泄漏；同时 9 个站点补 `sanitizeForAI`
（顺带修掉会触发 Kimi 400 的 `[表情]` 一类占位符没被剥掉）。

证据强度：变异实验把出口那行改回原样，测试直接打印出真实请求 body ——
`"content":"【边界】…收 13812345678 联系我\n卡号 6222021234567890123…"`。
这不是推理，是抓到的字节。

### §101 老版本写下的设置 blob 让账号"看起来被清空"（commit 98c99d92）

`SyncConfig`/`NotificationConfig`/`AppUpdateConfig` 用合成解码：非可选属性一律必填，
属性默认值不参与解码。而 `AccountStoreCoordinator` 的设备设置迁移把老版本 blob
**原样**搬过来。缺一个 `displayScreen` → 整块解码失败 → `getSettingJSON` 返回 nil →
`?? SyncConfig()` → `wechatDBPath = "auto"` → 机器上有两个微信安装时解析不出账号根
目录 → 新建 `accounts/unconfigured/hud.sqlite3`。白名单、承诺、日报在界面上全没了，
真数据在旁边那个文件里没动。

改法：三条设置各自逐键容错（新增 `KeyedDecodingContainer.lenient/lenientEnum`），
"键不存在"和"整块读不出"分开处理 —— 后者按本类型既有策略直接拒绝启动，不再猜账号。
行为测试：种一个不含 `displayScreen` 的 legacy 库 → bootstrap → 断言 storePath 仍是
legacy 且 `getWhitelist()` 还在；变异（把 displayScreen 改回严格 decode）→ 该用例红。

顺带查到但不是本轮的：`initializeIfNeeded` 在 `legacyBindingRecorded=false` 且没有
legacy 文件时会把设备设置整份覆盖成空 —— 需要一次"设备文件在、legacy 已删、绑定
标记却没写"的写入中断才触发，定价为 P2。

### §102 洞察详情区在 body 里整读一天（commit da83200d）

侧栏早就改成 `computeDayStats`（nonisolated）+ `primeDayStats`，但详情区还留着
`insightStore.statsForDay(...)` —— 它是 @MainActor 的同步方法，底下是
`reader.getMessages(limit: Int.max, startTime:endTime:)`。更要紧的是侧栏对「今天」
直接跳过预取，而打开页面默认就是今天：每次选对话、每次换日期都在主线程解一遍该对话
当天跨的所有分片。

改法照抄侧栏：命中缓存立刻画，未命中先出"无统计"骨架，后台算完填回来。并且**删掉**
`InsightDataLoader` 的同步 `reader:` 重载（只留 actor 版），让这条路径写不回来；
唯一用到它的测试改成 async。

### §103 自动发送的三道资金闸用了三种归一化（commit 7623ed00）

信任边界代理报的两条，回源码都成立：

1. `applySafetyDowngrades` / `autopilotSafetyHoldReason` 走
   `normalizedForSafetyMatch`（lowercase + 繁简折叠），而最后一道
   `automaticSendHoldReason` 只做 `replyText.lowercased()`。同一套敏感词，最靠发送
   的那道最弱。另外归一化本身不认宽度与空格：「转 账」「轉　賬」全部绕过。
2. `financialTriggerCues` 只有 🧧/zhuanzhang/hongbao 三个、且只查入站不查回复；
   用户清空 `sensitiveKeywords` 就等于拆掉资金底线 —— 而且旧测试把这件事写成了期望
   （`testEmptyKeywordListReliesOnRiskAndReasonCode` 断言 转账 明文 + 空词表 = 可发）。
3. `evidence_quote` 解码后全仓零消费者：模型自评的 risk/confidence 是攻击者文本能
   直接影响的唯一依据。

改法：归一化统一成 lowercase → 繁简 → 宽度折叠 → 去空白/零宽（实测只去宽度折叠
不足以拦「轉　賬」，U+3000 要靠折叠变普通空格才被剥掉）；三道闸共用；资金线索补
汉字/英文支付通道、入站与回复双侧、图片 OCR 文本进扫描面；send 意图必须引用得出 ——
`evidence_quote` 不在我们真正发出的那段原文里就转人工。旧测试的期望改成新契约并写明
为什么改。

代价说清楚：这会让更多私聊落到"需人工确认"。产品方向上托管本来就默认关，宁可多问
一次也不要替用户对真人发一句资金承诺。引用回查对"模型改写了措辞而非逐字引用"会误判
成需人工，同向、可恢复。

### §104 取消关注改成一个事务，两处不可逆动作先确认（commit a4ae5905）

`removeFromWhitelist` 是 8 条语句、7 条 `try?`。中间失败就是"人已不关注、承诺还在
天天提醒、待办还在列表"，而界面按成功画。交互代理另外指出：审批工作台的「立即发送」
一次点击直接 AX 发出微信消息（同页「确认发送」却有确认弹窗），行内正文 `lineLimit(2)`
还会截断；收件箱右键的「取消关注此对话」一次点击触发上面那串连带清理，无确认无撤销。

改法：连带清理收进 `withTransaction`（`perform` 用 dispatch-specific key 做了重入保护，
`withTransaction` 自己支持 savepoint 嵌套，所以外层已持锁不会自锁）；store 失败时
ChatMonitor 不清内存态；`discussion_queue` 是首次使用才建的表，改走既有的
`clearDiscussionMessages` —— 否则一个没用过待办队列的新库直接取消不了关注（这一步是
测试逼出来的：先写严格 DELETE 后 `testSuccessfulClear...` 红）。两处补确认。

行为测试用"故意 DROP 掉级联中间那张表"来证明回滚，而不是只数条数。

### §105 扫描收尾的四遍全表修复：从每轮一次收到一小时一次（commit c636af98）

FSEvent `latency: 0.0` + NoDefer（0.5s debounce）加 10s 心跳 ⇒ 微信活跃时每分钟
6-10 轮扫描，每轮收尾都在主线程串跑：`displayNameCache.removeAll()` + 每个白名单条目
两次 SQL + 一次抢 reader 锁；`repairStaleChatNames` 的 15 张表 `LIKE '%@chatroom'`
全表扫；承诺对象修复；反问句倒置修复（`loadCommitments()` 不传 cutoff、无 LIMIT）。
代价跟着表本身涨，而这些都是"修好就不再变旧"的一次性归并。

改法照抄仓里已有的 `shouldSweepStaleRows` 论证（小时闸门 + 启动后第一次必跑），额外
加一条：`contact.db` 真的 mtime 变了立刻跑，那是唯一会让备注改名的信号。闸门函数
可注入 `now`，测试验的是"第二次不跑"（用命名缓存被清空来观察有没有真跑），不是读数位。

### §106 每行的显示名不再排在整分片解密后面（本轮）

`WeChatReader` 一把递归锁串起所有 DB 访问，而 `getDecryptedDB` 从头持到尾（整文件
读入 + 逐页 AES + 合 WAL）。`displayName(for:)` / `groupMemberNames` 抢同一把锁，
可它们一个数据库都不碰。后台扫描在解大分片时，主线程画一行就得整等。

**没有**把解密挪出主锁：`refreshIfChanged` / `refreshContactsIfChanged` 这些调用方
本来就持锁进来，再压一道"解密串行闸门"就是持锁等闸、持闸等锁的反向死锁 —— 这条路
我先实现过一遍，审出来后果比原来的卡顿严重，退掉了。改法是拆第二把锁：只护三张命名
缓存，读侧只拿它，写侧 `lock` → `namingLock` 单向嵌套，且整份 contact 索引 + 群成员
标签的发布收进同一个临界区（否则未命名群会在刷新中途闪成占位名）。主线程 apply 里
另外两次抢锁一起搬走：`purgeEphemeralCache` 挪到扫描的后台侧，contact 是否变过由
`ScanOutcome.contactsChanged` 带出来（后台 `prepareForScan` 早问过一遍，不必再问）。

这一条没法写成行为测试（要把私有锁在真解密中途按住，没有测试缝），落成源码闸门：
8 个命名查找函数必须用 `namingLock`、不得出现 `lock.withLock`。

### §107 群聊未读也在把抓取窗口当条数 + 一条被 §96 打断的测试

数据代理的 P1 与 §99 同一类：群聊分支对页内每条"已在手机上读过"的 @ 逐条计数，
1 条未读的群能把 31 计进 `未读 N 条` 和 @ 角标。改法是把该房间的贡献封顶在
`session.unreadCount`（页是新的在前，所以留下的正是没看过的），行与计数一起封顶，
避免出现"数字封顶、行还全出"的第二套口径。

另外：本轮全量跑测发现 `BannerSnoozeFailureTests.testASavedSnoozeStillHandsOffToTheInbox`
在 §96 改文案后一直红（它断言旧措辞「已安排」）。原因是 §96 那轮只跑了
`CompanionProductCopyTests` 就收了 —— 改一条共用文案时，要跑的是所有断言这条文案的
测试，不是新增的那一个。断言改成契约（回执要说清"回到收件箱"）而不是某个短语。

### 本轮定价但没改（下一轮的起点）

P1 未修：
- `GitHubReleaseFeed` 只校验 `scheme == https`，`browser_download_url` 无 host 白名单；
  zip 整份缓冲进内存、无体积上限、`.sha256` sidecar 可选。验签链路本身是硬的
  （降级拒装、名单校验、二次验签 + 回滚隔离），所以这不是"装上恶意包"，是"被指到
  任意主机无界下载"。需要 host allowlist + 流式上限 + 强制 sha256。
- `WeChatParser.parseSysMsg` 缺 `parseAppMsg` 的两道闸（doctype/entity 拒绝 + 长度上限），
  而群系统消息夹带成员可控昵称 → 实体展开放大。
- `ImageResolver` 三处整文件读入只为验 4 字节魔数 + 再整份 XOR 复制；
  media-cache 键含尺寸 ⇒ 远端可无限堆缓存文件。
- 锁屏通知正文带 ≤80/100 字原文，且没有"只显示提示不显示正文"的开关。
- 日报导出到桌面的 markdown 带未回 preview 与撤回原文、0644，开了桌面 iCloud 就上云。
- 浮窗 `sharingType` 全仓 0 处设置 ⇒ 投屏/会议录屏可捕获岛正文。
- 队列去重把 `content_key` 当身份（不含 localId）→ 同秒同文本的第二条永不进分类。
- 日报「今日小结」里来自 discussion_items 的待办点「完成」：`relatedID` 是
  `"discussion-<id>"`，`Int(...)` 恒 nil 且无 else → 只从当天日报消失。
- autopilot 分支的裸 `Task {}` 自造第三路扫描触发、`stop()` 不取消它；
  `generateSummaries()` 没有单实例守卫；`loadContacts()` 掉进分类循环里。
- `analysis_cache`/`ai_feedback`/`vip_traces` 等只按同 key 命中才懒删，常驻数周无界增长。
- 岛内「稍后提醒」的 ✕/时钟命中层只有字形大小（应 22×22 + contentShape）。
- 排除名单的红色减号一次点击即把某客户放回自动回复范围，无回执。
- `Int(sqlite3_column_text(...))` 裸读唯一允许 NULL 的 `discussion_items.detail`。
- `AIService.acquire()` 吞掉 CancellationError，被取消且窗口满时自旋。

P2/闸门类：默认签名身份 `WeChatHD-DevCert` 走无 hardened runtime 分支、全仓无
.entitlements；Info.plist 只声明 `NSAppleEventsUsageDescription` 而真实能力是 CGEvent
键鼠注入 + 通用剪贴板；表名直插 SQL（需能写微信库才可利用）。

### 本轮结论

七路审计报的 P0 共 15 条，逐条回源码：14 条成立（全部已修并带行为/闸门测试 +
变异验证），1 条按证据降级（安全代理自报 P0 为 0，其 3 条 P1 见上）。
另有本轮自查发现的 3 条同类缺陷（群聊未读口径、被 §96 打断的测试、§99 的窗口口径）
一并收口。全量 `swift test` 与 release 构建的结果以本轮收尾运行为准，写在上面各节的
commit 里。

---

## 第 29 轮：四路复扫（出网掩码形状 / 托管护栏可达 / 常驻成本 / 数据完整）

派单口径：四路只读代理，各自一个不重叠的轴，每条结论回源码复核后才动手。

### §108 出网掩码只认「连续 ASCII 数字」——分组、全角、零宽一律原样出网（commit ccf59f67）

两路代理（AI 出网轴、隐私轴）独立收敛到同一条：`maskDirectIdentifiers` 的四条
正则要求数字**连续且为 ASCII**，而 `sanitizeForAI` 调的就是同一个函数，所以
「忘了在调用点 sanitize 还有出口兜底」这句话在号码形状上根本不存在第二层网。

回源码 + 变异实测坐实（关掉形状归一后，测试直接把原文印了出来）：

| 输入 | 修前 | 修后 |
|---|---|---|
| `138 0013 8000` / `138-0013-8000` | 原样出网 | `[手机]` |
| `１３８００１３８０００`（全角键盘） | 原样出网 | `[手机]` |
| `1380<200B>0138000`（零宽隔断） | 原样出网 | `[手机]` |
| `+8613800138000` / `86 138 0013 8000` | 原样出网 | `[手机]` |
| `6222 0202 1234 5678` | 原样出网 | `[卡号]` |
| `someone<FEFF>@example.com` | 原样出网 | `[邮箱]` |

中文聊天里带空格/破折号的号码是常态写法，不是对抗样本。

修法没有继续堆正则：分隔符一放开，`会议 2026-09-19 2026-09-20`（16 位）就会被
当成卡号吃掉，而「用户正在问的数字不能动」是这条边界自己写明的契约。改成按
**位数 + 分组**判定（分组每段 ≥3 位，唯一的 2 位例外是前导 `86`），日期段是
2 位分组所以天然出局；`.` 与 `,` 刻意不算分隔符，`1,380,013,800` 这类金额保持
原样。变异验证：放开分组约束后测试立刻报 `会议 [卡号]`。

定价未做：卡号 13/15 位（Visa-13/AmEx-15）仍不掩——13 位会吃掉毫秒时间戳，
16-19 位维持原样；20 位以上长数字串里内嵌的手机号仍漏（修前也漏，`(?!\d)` 决
定的）；固话、wxid、姓名/群名不在掩码范围（已把这句写进函数注释，别让下一轮
把「兜底」读成「全覆盖」）。

### §109 解析不出的 action 会被当成发送许可（commit ccf59f67）

护栏轴报的这条链子在源码里逐跳坐实：prompt 词表只有
`send|stall|read_no_reply|skip`，解码器把**任何词表外的 action** 折叠成
`pending=true`（兼容 v1-v3 布尔字段），而 `AutopilotService` 的注释写着
「AI says pending or stall → treat as stall（自动发一句缓兵之计）」——于是
`"hold"`、`"confirm"`、JSON 截断半个词这类普通模型抖动，等于把它自带的
`reply` 文本排进自动发送队列。

变异验证打出来的实物就是证据：

```
PendingSend(replyText: "周末安排还不确定，周五再定", confidence: 0.99,
            manualOnlyReason: nil)   ← 定时器到点即真发
```

`AutopilotSafetyTests.testUnknownAutopilotActionForcesPending` 早就存在，但它断言
的是**解码器**把 pending 置真，恰好把这条错误折叠当成了正确行为钉住；消费者一侧
零覆盖。现在解码器多带一个 `actionUnrecognized`，消费者在安全表之后强制降为
`.pending`（发送意图闸门拒收），且空 reply 时不再落到「已读不回」——那条分支会
真的去打开微信窗口，等于给一个读不懂的响应批了外发副作用。

同轴第二处：`evidence_quote` 回查原先只在 `action == "send"` 时执行，注释写着
「stall 什么都不发」——而 stall 的定义就是发一句缓兵之计。改为 send/stall 都要
回查原话。

### §110 不可读 sync 的拒绝发生在删除 legacy 副本之后（commit ccf59f67）

上一轮我为了让「坏 blob 不被当成未设置」而加了拒绝，但拒绝点在
`deleteSetting` 之后：首次引导时五个共享 key 先被原样拷进 `device-settings.json`，
legacy 表里的那份随即被删，然后才抛出。此后每次启动都抛，而唯一的出路（删
device 文件）会把已被清空的 legacy 里的**出厂默认**再种回去。改成先判断再删，
并补测试钉住「拒绝不得消耗它正在保护的那四份设置」。

### §111 洞察页把每次扫描当成一次全库重算（commit ccf59f67）

`ChatInsightView` 挂着 `.onChange(of: monitor.stats.lastSyncAt) → reload`，而
`lastSyncAt` 每次扫描完成都会打新时间戳（有无新消息都一样），`stats` 又是无条件
赋值 ⇒ 默认 30s 一次。一次 reload 是 `bulkMessageStats` 的全库归并（代码里留着
本机实测：4648 个分片/表组合、约 28.8 万行）。上一轮只是把它从主线程挪到后台，
没动频率——挪走之后它不再卡窗口，但会一直占住 reader actor 与解密锁，让扫描排队。

现在扫描 tick 走 `ReloadTrigger.newData`：300s 限速、正在跑就不叠加、且**不清空
页面**（每几分钟闪一次加载态会被读成崩了）；用户主动开页/换窗口/换范围/换日期仍是
`.userInitiated` 即时生效，若正好有一次全库归并在跑，则记一次重跑，避免页面标题
写「近 30 天」而数字还是「今天」。闸门测试在 `ResidentCostGatesTests`。

同轴另两处已修：`dfsAX` 原先只有深度上限、没有节点上限（一节点 1-4 次阻塞跨进程
读），且全仓没有 `AXUIElementSetMessagingTimeout` —— 这些遍历全跑在画岛的主线程
上；补 0.5s 超时 + 2000 节点预算。

### §112 我上一轮引入的两处退化（自查）

- `AIClassifier.interpolate` 现在对 `{message_body}` 做 `sanitizeForAI`，纯图片消息
  于是变成**空正文**，而 `classifier_v4.txt:107` 还在教模型处理字面量 `"[图片]"`
  ——那个输入已经永远到不了。分类链路上也没有媒体预过滤，等于让人名当锚点盲判。
  改为：净化后无正文的消息直接确认、不出网（prompt 本来就规定图片不是 ask，
  决策等价，省一次调用）。
- `AIInboxSummarizer.renderMessageBody` 先 sanitize 再 `isMediaPlaceholder(sanitized)`
  ——占位符正是被 sanitize 删掉的东西，该判断恒 false，媒体快路径是死代码，目前
  只是靠后面两次 fallthrough 侥幸得到正确答案。改为对未净化的原文判断。

### §113 联系人页的删除漏掉连带清理（commit aef6aba8）

`removeFromWhitelist` 上一轮收成一个事务并清了承诺/待办/静音/稍后提醒，但它的同类
项 `deleteContactAndTracking`（联系人页的删除）走的是另一个私有 helper，只清
`whitelist/sync_state/chat_actions` 三张表：承诺、待办、讨论消息全部活下来，用户在
那里已经看不到它们，却仍会被「承诺到期」提醒。抽出一个 `clearDerivedArtifacts`
让两条显式取消关注路径共用同一个作用域；**灰名单降级仍不清理**（可逆的等级变化，
界面也没给这份连带提示），这个不对称单独用测试钉住。

### 本轮判阴（别在下一轮重复上报）

- 「坏 `ai` blob 会让下一次开关把 API key 从 Keychain 删掉」：不成立。
  `hydrateAPIKey` 在 `keychainItemRef` 为空时回落到默认账号，密钥会被重新读回来，
  于是那次保存走的是「非空 → 重写」分支。已写的防御改动**退回**，只把这条链路
  本身钉成回归用例（含「用户仍可主动清除」这一侧）。
- 「岛内 `.confirmationDialog` 在 borderless nonactivating panel 里可能根本不出现」
  ：实测出现。探针把 `confirmUntrack` 置真后，面板 `attachedSheet` 被挂上，
  `_NSAlertPanel` 以 level=101、frame 260×173 存在且 2.5s 后仍在；harness 的
  overlay 分支能拍到它（520×346px）。**但位图里只有 SwiftUI 那颗红色按钮，
  AppKit 画的标题/正文不在 contentView 截图内**（明/暗两档都一样，而 173pt 的高
  度正是给这两行文本留的）——这是 harness 的覆盖面限制，不是产品没画。

### §114 打开「自动发送」会一次放出整条历史积压（commit b9b5dde9）

`handleNewMessages` 从不看 `autoSendEnabled`，只有 `processPendingQueue` 看 ⇒ 开关
关着时排进来的草稿一直 `manualOnlyReason == nil`、一直"到点即发"；而
`stalePendingSendReason` 只找"排队之后有没有新消息"，对方就此安静下来时它反而放行。
结果：用户某天打开自动发送，几小时甚至几天前的草稿会一次性发进早已翻篇的会话。
现在队列在处理前先做一次退役：超过自身延时窗口（10 分钟，真人延时上限是 300s）
的草稿转为人工确认并落库，仍在待批工作台里可见、可手动发送，只是不再无人值守。

### §115 撤回的连带清理原先是三条 `try?`（commit b9b5dde9）

`tombstoneForRecall` 与取消关注同形，但它没有重试机会——扫描水位线无论成败都会
越过 revokemsg 行。三条语句改成 `withTransaction` + 抛出，调用点记录失败而不当
成功；半应用状态（承诺已取消而 pending_asks 还在）不再可能出现。

---

## 第 30 轮：六路复扫（撤回归因 / 外源数值 / 自破的掩码 / 发送簿记 / 生命周期 / 界面承诺）

### §116 同名群友会互相顶掉撤回墓碑（P0，commit dbdc0336）

`recordRecall` 用 revokemsg 文本里的人名去 10 分钟窗口内认领原消息
（`$0.senderName == owner || $0.senderUsername == owner`），拿到 id 就直接
`tombstoneForRecall`：承诺→cancelled、待办→dismissed、pending_asks 删除。微信的
撤回提示只给**显示名**，而同一个群里两个成员叫同一个名字是常态；管理员撤回其中
一个人的消息时，`first(where:)` 会认领到另一个人的那条，把他的承诺和待回连根删
掉。这条路径没有重试——扫描水位线无论对错都越过 revokemsg 行，所以错删是永久的。

现在先数窗口内该名字被几个不同 `senderUsername` 认领，≥2 就只记录撤回事件、不做
任何连带清理，也不把别人的原文写成"被撤回的那条"。私聊与"自己撤回"不受影响
（后者走 `isFromSelf` 的 id 判定，不依赖名字）。

测试 `ScanEngineRecallAttributionTests`：同名两人 ⇒ 两条承诺都活着、撤回行的
`original_text` 为空；唯一同名 ⇒ 照常墓碑并带上原文；自己撤回 ⇒ 不受新闸门影响。
证伪：把 `>= 2` 改成 `>= 99` ⇒ 2 条断言失败。

残留（已知、无法在此调用点消除）：同名的两个人里只有一个在窗口内发过言时，仍然
只有名字可依据。要真正分辨需要群成员名单，reader 的 `name2id` 只在单次查询内部
可见。宁可少删不可错删，所以这种情况仍会墓碑——但它要求"另一个同名者这条窗口内
没发言"，比原来的"任意同名"已经窄得多。

### §117 `unread_count` 先乘 2 再钳制，坏值直接 trap 掉常驻进程（commit dbdc0336）

`unreadFetchLimit` 的群聊分支是 `session.unreadCount * 2`，而 `unreadCount` 来自
`Int(sqlite3_column_int64(...))`——微信自己写的列，本仓不写也不校验。超过
`Int.max/2` 的值（损坏库或未来 schema）会在钳制之前触发溢出 trap，进程消失。改为
先把 unread 钳进 `[0, unreadWindowCap]` 再翻倍；私聊分支的页大小逐值不变（40 仍
是 40，测试钉住）。证伪：把乘法移回钳制之前 ⇒ 测试进程直接死掉而不是报失败，这
正是原缺陷的形态。

### §118 上一轮收紧分组规则时，把最常见的身份证写法放行了（自查回归，commit dbdc0336）

§107 为了不吃掉 `2026-09-01~2026-09-30` 这类日期段，把分组判据收到"每组 3-4 位"。
但 18 位身份证人手抄时最常见的是**印刷分节 6-8-4**（地址 6 + 出生 8 + 顺序 4），这
个形状在收紧后整条不匹配 ⇒ 原文直发配置好的 AI 端点，而 `maskDirectIdentifiers`
是全仓唯一的标识符清洗器、没有第二层。补回该形状：仅当恰好 3 组 6/8/4、且中间 8
位能读成合理生日时才判 `[证件]`，因此 8-8 的日期段与 8-8-4 的流水号照旧不动。

同一处还有一个自造的代价：贪心下探从"当前组一直到行尾"构造窗口，对端发一串 500
段 8 位数字就能让每次掩码做 2·10⁵ 次构造。改成按"任何标签都不超过 19 位、外加
`86` 前缀"设宽度上限（`maxClassifiableDigits = 21`）。

测试：`AIOutboundPrivacyBoundaryTests` 新增 6-8-4 三种写法（空格/连字符/带 X 校验
位）都被掩掉、8-8 与 20 位墙仍原样保留、数字风暴之后的手机号照样被掩。证伪：删
掉 `isIDCardChunking` 分支 ⇒ 3 条失败；把上限设成 0 ⇒ 风暴后的手机号漏出。

### §119 已核实送达的回复仍留在"待确认"上，再点一次就是第二次真实发送（commit dbdc0336）

`executeSend` 成功后的簿记是两条独立的 `try?`：先删 `autopilot_pending_sends` 行，
再翻 `autopilot_log` 孪生行。第二步失败被吞掉时，队列行已经没了而日志仍是
'pending' ⇒ 审批工作台继续提供「确认发送」，点下去对方就收到第二遍。同理
`markAutopilotLogSent` 自己是 2-4 条语句（unverified 声明、skipped 翻回、pending
翻回、legacy 兜底），半应用会让同一条回复既是 'sent' 又仍在等人确认，
`sessionPending` 也跟着算错。

改为一条 `resolveVerifiedSend`（删行 + 翻孪生行同一个事务），三个 `markAutopilot*`
函数整体收进 `withTransaction`。失败时回滚成"队列行还在"，这条退化路径由两道既
有闸门兜住：内容闸门 `stalePendingSendReason` 会在会话里读到我自己那条已发出的
消息而拒绝，时间闸门 `isStaleForAutomaticSend` 让它过 10 分钟后转人工。

测试 `VerifiedSendResolveAtomicityTests`：注入 `BEFORE UPDATE ON autopilot_log` 的
触发器让第二步必败 ⇒ 队列行必须还在、孪生行仍是 pending（回滚），成功路径则两条
一起消失。证伪：把事务拆开 ⇒ 失败即复现"行被删了而状态没翻"。

### §120 「等待微信重新登录」的 2 秒轮询没有终点（commit dbdc0336）

`awaitFreshWeChatRelogin` 是 `while !Task.isCancelled`，而它跑在一个句柄被丢弃的
`Task { }` 里，`stop()`/`.onDisappear`/`deinit` 都碰不到它；每一 tick 会 spawn 一
次 `/usr/sbin/lsof`。用户放着不管（关掉设置、也不重开微信）时，常驻浮窗就整会话
每 2 秒起一个子进程。加 10 分钟截止并在到期时把阶段改成「已停止等待」——原来超时
只会悄悄返回 nil，页面停在 `.waitingForWeChatRelogin` 上继续承诺一个已经不存在
的等待。

### §121 回顾页把"崩掉的那次"显示成「已完成」（commit 5941c22b）

`latestCompletedRun()` 只取 completed/partial，失败信息只在本次会话的 job 状态里
渲染过。一次跑挂的回顾会留下 `status='failed'` 的行，重开应用后页面于是拿更早一
期的内容顶着「已完成 · <旧日期>」显示，用户以为这一期已经看过、里面没有风险项。
新增 `latestReviewRunAnyStatus()`，状态行先看有没有"最近一次其实没跑完"，有就写
「最近一次回顾（时间）没有完成 · 下面是上次成功的结果」，并且当页面已经横幅报错
时不重复播报。状态行抽成纯函数，测试直接对三种输入断言措辞（含"不许再出现已经完
成"）。证伪：短路掉该分支 ⇒ 2 条断言失败。

### §122 洞察 reload 的排空尾巴从 `if` 改 `if`→`while`（无测试）

尾巴是 `if userReloadWhileBusy` 时，若用户在**尾巴那次重算进行中**再点一次刷新，
标志会留到下一次 5 分钟的自动 pass 才排空，而那一 pass 用 `clearsView: true` ⇒ 用
户没碰任何东西却看到整页转圈。改成 `while` 后标志在同一趟里被重新读到。理由来自
读控制流（`:135-137` 的早退 + 尾巴的位置），没有配套测试：要复现得让
`performReload` 中途可悬挂，得先给 walk 注入钩子。留作下一轮的治具项。

### §123 用户正在用微信时，自动托管会自造一条无限全量扫描（commit 4f7a30f3）

`handleNewMessages` 之后有一段"批次还没排空就过会儿再扫"的续命逻辑。但暂停期间
`allExpired` 被强制成空 ⇒ `batchBuffer` 永远非空 ⇒ `hasPendingBatches` 永远为真 ⇒
每 `batchWindowSeconds + 1` 秒重进一次 `scan()`（全库读取 + rebuildInbox + 提醒引擎
+ AI 预取）。触发条件是一条普通私聊文本，而"微信在前台"正是这个 HUD 用户最常见的
状态。现在这条判据收进 `ChatMonitor.chasesPendingBatches(hasPending:paused:)`，暂停
时不追扫，排空交还给 10s/60s 的安全心跳（它本来就在扫）。
测试含判据本身 + 调用点锚点。证伪：把 `&& !paused` 去掉 ⇒ 1 条失败。

### §124 详情面板会把甲的聊天记录回填进乙的窗口（commit 4f7a30f3）

`loadTranscriptAndIdentity` 在两次 `await`（各自 hop 到一个新建的 reader actor）之后
无条件写 `transcriptRows`；而 @ 跳转那条路径起的是 `.task(id:)` 取消不掉的裸
`Task {}`。取消在这里也不够用：被等的读不观察取消点，输掉的那次照样落地。快速在
对话间切换时，甲的消息气泡会出现在乙的标题下面，`selfNames` 也跟着错位（甲的话被
画成"我说的"），用户接着照着甲的内容编辑并发给乙。改为写入前校验本次请求的 token。
`StaleViewShapeGatesTests` 钉住"守卫必须在最后一次 await 之后、写 transcriptRows
之前"。证伪：拆掉守卫 ⇒ 1 条失败。

### §125 未来的消息时间戳能把「忽略」变成永久静音（commit 4f7a30f3）

`dismissInboxItem` 用消息自身的时间当"已处理到这条"的水位写库，
`rebuildInbox` 读回时 `silencedAt > permanentThreshold` 的解释是"这个对话永久静音"。
一条时间超前的消息（改过系统时间的对方客户端、或损坏/未来 schema 的库）就让那个对话
再也不出现。同一行的 `Int(date.timeIntervalSince1970)` 还有第二个问题：
`Double(Int64.max)` 会舍到 2^63，转换本身 trap。三处水位写入统一走
`MessageHelpers.watermarkSeconds`（上限=此刻，非正/非有限=0）。
测试覆盖超前、Int64.max、负数、NaN 与正常值；证伪：把上限去掉 ⇒ 测试进程直接
`Fatal error: Double value cannot be converted to Int`，即原缺陷的真实形态。

### §126 §121 当时是死代码（自查 + 被"攻自己 diff"的子代理抓出）

回顾的放弃标记在 `refreshLatestRun()` 里设上，又在它下一行调用的 `load()` 里被清掉
⇒ 只要历史上有任何一次成功，诚实分支根本不可达。而我的测试没发现，因为它直接调
纯函数、对"接线"部分只 grep 了源码文本。教训：**grep 式接线断言不算行为测试**，它
只保证字符串在，不保证数据流。现在两个字段由同一个 `runState(from:)` 决定，
`load()` 不再参与，并且顺带覆盖了"作业随应用一起死掉、35 分钟内还是 'running'"这一
类（以前会往反方向撒谎）。测试改为对真库断言 `runState` 的两值，证伪：恢复"后写
覆盖"⇒ 失败。

同一次自查还把撤回的同名认领范围从 10 分钟匹配窗口扩到整页候选——另一个同名的人
这一小时没发言，不构成"窗口里那条就是他"的证据（证伪后 1 条失败）。

### §127 定长直方图按固定位置裸索引（commit 36bb07fc）

`ForEach(0..<24)` 配 `messagesByHour[hour]`、`ForEach(0..<7)` 配
`messagesByWeekday[i]`，长度约束只存在于生产者；同一形状还在 `ChatInsightEngine`
的跨对话聚合里（`for i in 0..<24 { hourly[i] += s.messagesByHour[i] }`，而
`messagesByWeekday` 在这一域里确实存在 `[]` 的取值，守卫只查了 `isEmpty` 而不是
长度）。少一格是"打开洞察总览时进程消失"。统一走 `MessageHelpers.buckets(_:count:)`
补零/截断：少一格从崩溃变成少一根柱子。测试断言归一函数本身 + 三处渲染点都调了它。

### 第 30 轮判阴与定价（逐条回源码验过，故意不改）

1. `approvePending` 的"翻孪生行 + 删队列行"仍非原子。方向与 §119 相反：先翻后删，
   半途失败留下的是"日志已 sent、队列行还在"，而队列行的 `manualOnlyReason` 非空 ⇒
   永不自动发出，人工点「立即发送」时 `stalePendingSendReason` 会在会话里读到我那条
   已送达的回复而拦下。子代理自己确认重复发送不可达，故不再动。
2. 6-8-4 的**订单号**（如 `120105-20251219-0032`）会被过掩成 `[证件]`。这是故意的：
   多掩一个号让 AI 少一个引子，少掩一个身份证是把原文发出去。要再收窄只能加省份码
   白名单，而 `120105` 本身就是合法区划码，收了也不解决该例。
3. `Date(timeIntervalSince1970: Double(msg.createTime))` 在仓里有 14+ 处，只有写持久
   水位/缓存戳的那三处会出事（§125 已收口）。根治要在 reader 出口对 `create_time` 做
   区间钳制，但它同时进 `contentKey` 与排序键，风险面比收益大 ⇒ 留作独立一轮，配套要
   先把"钳制后旧行的 contentKey 变了会不会重复入队"量清楚。
4. 群成员静音按显示名落库（`ignoreSender(senderUsername: "")`）：同名成员一起被静音，
   别人改名成被静音的名字就静默丢消息。要修得先让 `InboxItem` 带上 `senderUsername`。
5. `ConversationDetailView` 的「暂无消息记录」把读失败说成没人说话（`recentMessagesAsync`
   里 `try? → []`）。同一个 reader 在发送路径是会报"无法读取发送前记录"的，这里没有。
6. 洞察页的「约 N 条 / 约 N 人 / 已等 3 小时」是模型填的数，没有任何一栏回算，UI 也
   没有"这是推测"的标记，雷达严重度还直接吃这个伪造小时数。
7. `queryAll/queryOne/scalarCount` 把 `sqlite3_step` 的错误当成"读到结尾" ⇒ 计数悄悄变
   小、主动提醒不再触发。已有 `queryAllThrowing` 系列，但扫描链路没人用。
8. 取消关注不清 `conversation_memory / ignored_senders / group_member_rules /
   vip_traces / recalled_messages / analysis_cache`。**故意不清**：再关注时丢掉数月记忆
   比留着更伤人，而 `recalled_messages.original_text` 是敏感原文，留着也有隐私面——
   这是产品决策，不是顺手加几条 DELETE。
9. `actionPrefetch / vipInsights / unsavedReplyDraftEdits` 只写不删；`ChatMonitor.stop()`
   不解除 `start()` 注册的观察者（当前两个调用点互斥 ⇒ 潜伏，不是现役损伤）。
10. `review_runs` 的窗口衔接：失败那期的 `range_end` 不算进下一次的起点 ⇒ 会重扫一遍
   （AI 成本，不漏内容）；partial 那期的 `failed_chats` 永久落在所有后续窗口之外。
11. §116 的残留：同群里两个同名成员、只有一个在 10 分钟窗口内发过言时仍会错认。要
   分辨需要群成员名单，而 reader 的 `name2id` 只在单次查询内部可见。
12. 小面：`AssistantTodayView` 徽标「N 项」只渲染 `prefix(3)` 且无 +N；
    `CommitmentTabView` 「可在『已完成』列表随时查看」实为 14 天窗口；
    `AdmissionSettingsView` 的静音规则读失败时整块变空。

### §128 模型编出来的「已等 3 小时」被当成测量值用（P0，commit 0558f604）

`waiting_hours` 由模型填：每对话提示词只给它 `[mN][epoch][sender]` 这种裸时间戳，
全局简报连时间戳都不给，却照样返回一个小时数。它没有被任何代码回算，直接进了：
雷达严重度（`waitingHours >= 2 ? .high : .medium`）、红字「需要你立即处理」行
「林晓 · 等 3 小时」（按钮是"打开对话去回复"）、以及导出 Markdown 的「## 需要你处理」。
也就是"一个没人量过的数字，长得像量过的，并且驱动用户去发消息"。

收口在解码边界：`WaitingItem`/`ActionRequiredItem` 的 CodingKeys 里删掉
`waiting_hours`，字段改为带默认值的 `var`，所以模型怎么填都进不了内存；各处既有的
`> 0` 分支自动退到不带数字的写法。预览夹具也改成不带小时数——否则像素质检会批准一个
生产到不了的分枝（假通过）。
测试 `testInventedWaitingHoursNeverReachTheRadar`：喂一段 `waiting_hours: 9` 的真实
HTTP 响应，断言结果里是 0、雷达里既没有「已等」也不是 high。证伪：把 CodingKeys 的键
加回去 ⇒ 3 条断言失败。

**这不是把功能做对了，是把谎去掉了**：正确的下一步是"用真实时间戳算出等待时长"
（提示词里本来就有每条消息的 epoch，收件箱那侧 ReplyDebtScorer/VIP 档位已经在算），
把这栏重新点亮。当前状态是雷达不再有"等很久"这一档红级——功能降级，已定价。

### §129 扫描水位可以是未来时间 ⇒ 该对话永久不再被看见（P0，commit 0558f604）

`setWhitelistCursor` / `setAutopilotCursor` / `setBackfillCursor` 原样写入
`create_time`。游标只前进，所以一条时间超前的消息（改了系统时间的客户端、损坏或
未来 schema 的库）一旦进游标，之后所有真实消息都比较成 `createTime > baseline` 的
反面 ⇒ 该对话不再进分类、待办、承诺提取与自动托管，重启不恢复，要等墙上时钟追上去。
同文件的提醒路径早就为此写了 `min(nowEpoch, max(...))` 并注明"session 行报未来时间戳
偶尔会发生"，游标路径漏了这道闸。

收口在持久化边界（`clampedCursorTime = min(max(value,0), now)`）：三个写入点共用，
负数收成 0 即"没有游标"，读回为 nil ⇒ 宁可重扫也不当成已读。测试
`ScanCursorClampTests` 覆盖三条写路的钳制、正常值逐值不变、负值与 Int.max。
证伪：把共享写入里的钳制改回原值 ⇒ 2 条失败。

### §130 浅色外观走查（emil 标准轮 4）+ 阈值语义提进可视层

浅色（`--preview-light`）此前基本没走过（全文只提过 7 次）。本轮走查 today /
我答应的事 / 聊天回顾 / 待办 / 关注谁 / 关系雷达 6 页：

- **侧栏选中洗层达标**：初测判"洗层丢失"是假阳性——采样落在行间空隙，扫列
  （x=250 逐行）证实选中行 y=188–246 有 g-r +7.9 的玉洗（行底 +2.0），正是
  v3「安静的玉色浅洗」的强度。焦点环为系统蓝，正常。
- **语义色浅色下全部正确**：橙=到期/超时线、红点=有更新、玉=主操作、红=移除关注。
- **1 处真缺陷已修**：关注列表行的 `120 分钟` 是裸阈值数值——语义只活在
  hover/AX（576 行注释记录了旧处置），扫读时被当成"已等 120 分钟"（§128 同类
  误读）。行内改为「120 分钟算超时」，与详情面板「120 分钟没回算超时」同口径。
  验证：同区域墨迹像素 668→823（+155 = 「算超时」三字），二进制 grep 含新文案。
- 承诺页副标题同轮已修（「不受保留档位影响」→「14 天内创建、到期或动过的都会显示」，
  对齐 `commitmentRelevantSinceClause` 的三路 OR 窗口语义）。
- 关系雷达空态、关注谁「TA 是谁」空态、待办详情免责句均达标（原因 + 下一步 + 不冒充）。
- **待重拍**：aiButler / autopilot / guide 三张——批量串行截图哨兵超时后拷回了上一轮
  残留 PNG（aiButler 显示的是 contacts 页），不能作数。坑已记进像素质检 memory。
- 遗留小面：待办页「很久没处理的会收起」的「很久」未量化（改前需先量作用面窗口）。

### §131 HIG 实测轮：13 页点击热区与命名全覆盖（emil 标准轮 5-6）

`--preview-hig-audit=<秒>` 走 AX 树实测（截图测不出的两类缺陷：点击目标、纯图标的
spoken name/tooltip），配合 `caffeinate -u -t 3` + `caffeinate -i` 防休眠旧帧：

- **13 页全测**（今天/待办/关注谁/承诺/洞察/AI 与建议/提醒方式/AI 服务/自动回复/
  微信连接/使用偏好/本地资料/怎么用）：`iconOnly=0 smallIcons=0` 全程保持——
  没有一个按钮缺 spoken name，没有一个小于 22pt 的图标热区。
- **自定义控件热区 12 处达标**：8 个文本按钮/字段（字高 14-16pt）经
  `CompanionPressStyle`/`CompanionRowPressStyle` 自带 `minHeight: 24` 一处治全部；
  5 处 `DisclosureGroup` label（字高 15-16pt）经 `companionDisclosureLabel()` 单点判据；
  4 个搜索框以「整行点击聚焦」达成（SwiftUI plain TextField 的 AX 面固定为文字行，
  padding/frame 均改不动——框架报告口径，非可用性缺陷）。
- **口径豁免（平台控件形态）**：`.controlSize(.mini)` 按钮（17pt）、NSSlider 轨道
  （16pt）——系统控件规格，HIG 24pt 下限针对自定义控件。
- 复核实测：contacts 页 1→0 归零；aiService/autopilot 各 3→1（剩的即豁免项）。
- 过程中两次「DisclosureGroup 只换开头破坏闭合」编译错误当场修复——改尾随闭包
  结构必须连 label 闭包一起给，值得记住。

### §132 动效机会扫描（emil 标准轮 7，find-animation-opportunities）——0 条幸存

按该 skill 的四问门（频率/目的/速度/功能）对全部 seam 类过筛。该 skill 的前提是
Emil 的「You Don't Need Animations」——克制即产出。本产品是密排工作台（crisp
personality），建议预算本就该低。拒绝清单（每条注明击杀它的门）：

- 收件箱行增删过渡 —— **频率门击杀**：tens/day 硬切是 Finder/Mail 惯例（第 3 轮同判）。
- 贪睡菜单 origin-aware scale（从「⋯」按钮弹出而非岛顶）—— **确信度门击杀**：
  菜单本就贴行弹出，anchor 差距 20px 级，不值一条新 transition 变体。
- 空态图标轻入场（delight budget）—— **功能门击杀**：crisp 工作台的空态是
  「告诉用户下一步」的信息面，v3 简洁优先 +「错峰只留给使用指南」的既有决策。
- 洞察总览 KPI 卡错峰入场 —— **既有产品决策击杀**（v2 错峰封顶条款）。
- 关系雷达图形绘制动画 —— **功能门击杀**：用户要读的功能性图形，装饰妨碍阅读。

结论：现有动效系统（CompanionMotion 闸门 + companionStatusReveal + 弹簧 morph +
stagger 封顶）已经覆盖全部高频价值 seam；「不加动画」是本轮的正确产出。

### §133 新门禁证伪抽查（emil 标准轮 8，收尾加固）

对本轮核心新门禁做「删掉它会失效吗」的翻转验证：临时把
`CompanionMotion.strongContentFade` 的 reduceMotion 分支降级为全瞬切 ⇒
`CompanionMotionTests` **9 个断言立刻变红**（两档策略的跨界断言全部真实生效）；
手动还原（未用 git checkout）⇒ 29 项全绿、无残留破坏。门禁不是摆设。

### §134 emil 轮 4 欠账补拍 + 自动回复页拆卡（emil 标准轮 9）

§130 留的「aiButler / autopilot / guide 待重拍」（当时批量截图哨兵超时拷回上一轮残留
PNG）本轮补齐。`/tmp/wcsnap.sh` 已被 /tmp 清理，重建 `/tmp/wcsnap2.sh`：先清
`wechathud-*` 旧产物再启动（NULL_GLOB 防 zsh glob 不匹配时整条 rm 不执行的坑），
等 `wechathud-capture-done` 哨兵、kill app、三张 md5 互异才作数。

**aiButler（r18-light-aiButler.png）**：语义色、层级、渐隐、焦点环（系统蓝在选中行）
全部达标，无新缺陷。**guide（r18-light-guide.png）**：§27 的两处修复都在（第 3 步
「岛上报数，这里列明细。」、「群聊不会自动发出」），无新缺陷。

**autopilot（r18-light-autopilot.png → r18-light-autopilot-v2.png）一处拆卡 + 一个
潜伏 bug**：

1. 整页只有一个 `SettingsSection("发到什么程度")`，而卡里嵌着一个**内层同款
   `SettingsSection`**（`limitsBatchRow` 的「连发的时候」）和一个自带 13pt/medium
   小标题的「哪些一定交给你」块——分区标题与卡内小标题同权重，第一眼读成两张卡的
   两个标题（v1「一卡多功能拆卡」+ Grouping & mapping：邻近即关系，一个标题下的
   黑名单 disclosure 会被读成「连发时不会自动回复的人」）。拆成三卡，标题即内容：
   「发到什么程度」（5 控件行）/「连发的时候」（连发等待）/「哪些一定交给你」
   （强制人工规则 + 黑名单 + 高级）。
2. **读失败时的 inert 门此前只罩住最后一个 disclosure**：`.disabled(loadError != nil)
   .opacity(…)` 链在高级 disclosure 的修饰链上——SwiftUI 里这只作用于该兄弟节点，
   不会传播给前面的 toggle/滑条。注释写的意图（「Editable-looking and inert is worse
   than greyed out」）没有真正生效，loadError 时置信度滑条仍可拖（`save()` 被 gate
   不写，正是注释里描述的那个「拖了动了什么都没发生」）。现在门挂在包住三卡的
   `Group` 上，环境传播覆盖全部控件。无新测试（两处都是渲染结构问题，像素已锁）。

**Emil 全量 gap 复扫（防下轮重查，结论：0 缺口）**：裸 `withAnimation(` 仅剩显式
瞬切的 `withAnimation(nil)` 一处；`easeIn` 零命中（呼吸 pulse 用 easeInOut 属循环
例外）；动画时长 >300ms 零命中（命中的 `duration: 5/8` 是 toast 保持时长）；
`companionScrollEdgeFade` 覆盖面已全（`content` 各 case 均走 `.workspacePage()`，
设置页也是，§「设置页缺渐隐」的怀疑不成立）；onTapGesture 5 处均为输入聚焦/遮罩吞
点击，不是可提交控件，不适用按压反馈；无自定义 DragGesture，velocity/rubber-band
条款不适用；toast 进出场同路径（exit 缩回岛侧）；tabular numbers 已铺开。

**performance-cheatsheet.md（Emil 仓库最后一份未消化文档）**：web 性能清单，
映射项全部已被既有规范覆盖（transform/opacity → Core Animation 合成属性、
blur < 20px → v5 的 blur(2px) crossfade 规则、列表虚拟化 → Lazy 容器），0 新增行动项。
至此 emilkowalski/skills 仓库中与本产品相关的文档全部消化完（apple-design /
emil-design-eng / review-animations+STANDARDS / improve-animations+AUDIT /
find-animation-opportunities / animation-vocabulary / write-swift / performance-cheatsheet；
animate-expo / mobile-native / pick-ui-library / ask-sonner / prototype 为 web·Expo
专用，不适用）。

**§134 验证**：`swift build` 通过；`swift build -c release` 零警告（warning/error 0 命中）；
全量 `swift test` exit 0（XCTest 2298 条 / 10 skip / 0 失败 + swift-testing 全过）；
受影响套件（Autopilot|Settings|ChromeMotion|PrimaryAction|Companion）373 条 / 3 skip /
0 失败。像素证据：`r18-light-aiButler.png` / `r18-light-autopilot.png`（改前）/
`r18-light-autopilot-v2.png`（改后）/ `r18-light-guide.png`，存
`2026-09-18-island-pixel/`。教训记一条：`swift test | grep` 的 exit code 是 grep 的，
本轮两次「exit 0」都是假通过信号——验证退出码必须不经管道。

### §135 小面三条收口 + 像素取证（emil 标准轮 10，2026-09-22）

第 18 轮交接清单第 12 条的三条小面，修复本体在 v5 未提交批次里已就位
（`还有 N 项 ›` 溢出行、承诺弹窗 14 天文案、双名单 `unreadableRow` 失败态），
本轮做的是核验、补齐第三条的同类漏网、并把三条全部钉进像素与门禁：

1. **「随时查看」是同一句谎的第二处**：待办批量清空弹窗
   （`DiscussionWorkspaceView:236`）写着「可在「看已处理的」中随时查看或恢复」，
   而同文件 327/367 行自己就印着「完成或忽略的只留近 14 天」
   （`DiscussionLiveWindow.historyDays`）——与承诺页被修的那句一模一样的自相矛盾。
   改为「14 天内可在「看已处理的」中查看和恢复。」
2. **门禁** `RelativeTimeVocabularyTests.testWindowedHistoryListsStateTheirWindowNotAlways`：
   Sources 里「随时查看」零容忍 + 两句 14 天文案正钉。证伪口径同 §133 家族。
3. **渲染注入口**：`AdmissionSettingsView.Snapshot` 补
   `memberRulesUnreadable` / `mutedUnreadable` 两个布尔（离屏渲染像可渲染成功态一样
   可渲染失败态）。
4. **渲染证据** `testUnreadableRuleListsRenderTheirFailureNotAnEmptyList`：
   失败态 ink>0.02（不再整块变空）+ 与「列表恰好为空」的渲染**字节互异**
   （读失败不许长得像空）+ 先证确定性（同输入两渲字节相等，否则互异断言无意义）。
5. **像素取证**（全部核过「上次同步」= 启动时刻，防 §58/§130 的旧图坑）：
   - `r18-today-overflow.png`：徽标「4 项」= 全量计数、3 行 + 「还有 1 项 ›」。
     为此预览夹具补了 2 条承诺（`preview-promise-followup/-design`）——2 条夹具
     根本放不出溢出行，等于这条分支在预览里永远不可见（§80 同类陷阱）。
   - `r18-dialog-commitments.png`：「14 天内可在「已完成」列表中查看和撤销。」
   - `r18-dialog-tasks.png`：「14 天内可在「看已处理的」中查看和恢复。」
   - `r18-admission-unreadable.png` / `r18-admission-empty-lists.png`：失败态 vs 空态。
   新开关 `--preview-batch-clear` 把两个一键清空弹窗停靠在打开态（沿
   `--preview-today-missed` 的「原本只能点击到达」先例），两页共用一个开关。

**取证路上踩到的坑（比修复本身贵，记下来）**：`cacheDisplay` 在显示器休眠的会话里
会**回吐上一次被合成的旧帧**——21:15/21:18 两次「今天」截图拿到的都是 21:10 那次
承诺弹窗帧（同步时间 21:10 是铁证：`PreviewRuntime.seed` 每次预览启动都跑，
「上次同步」= 启动时刻，是免费的新鲜度 oracle）。§131 的完整配方是
`caffeinate -u -t 3` **加 `caffeinate -i`**，此前脚本只抄了前者；补上 `-i` 后
同参数重拍即为正确帧（同步 21:22）。判据一句话：**图里的「上次同步」不等于本分钟，
这张图就不作数。**

**§135 验证**：`swift build` 通过；受影响套件（Admission|Commitment|RelativeTime|
Discussion|ChromeMotion|Preview|Copy）297 条 / 3 skip / 0 失败（真实退出码，不经管道）；
新增渲染用例 1 条 + 词汇门禁 1 条均实跑通过；全量 `swift test` 见下节数字。

**§135 收口数字**：全量 `swift test` exit 0 —— XCTest **2300 条 / 10 skip / 0 失败**
（较上轮 2298 净增 2 = 本轮渲染用例 + 词汇门禁），swift-testing 72 条全过；
`swift build -c release` 零警告。

### §136 §130「很久」销账 + §88 回顾窗死区收口（emil 标准轮 11，2026-09-22）

**§130 遗留「很久没处理未量化」已销——修复本体在 v5 未提交批次里，记录过时了。**
git diff 证实四处全部改为 `\(DiscussionLiveWindow.pendingDays) 天没处理` 插值
（327/328/367 行的解释句 + 分组头「N 件很久没处理，点开查看」），与自动清扫的真实
作用窗（`ChatMonitor.reloadPendingDiscussionItems` 的 `archiveStalePendingDiscussionItems
(cutoff: pendingDays)`）同一把常量尺子。本轮补的是它欠的证据与门禁：

- 像素 `r19-tasks-window-copy.png`（同步时间 = 启动时刻的新鲜度铁证）：
  「当前只显示还没做完的。14 天没处理的会收起，不占这个列表。」
- 门禁升级：`testWindowedHistoryListsStateTheirWindowNotAlways` 的禁语扫描加
  「很久没处理」（与「随时查看」同罪：一个隐瞒窗口、一个谎称没窗口），并正钉
  `\(DiscussionLiveWindow.pendingDays) 天没处理的会收起` 这句插值在源码里。

**§88 回顾窗死区收口（532pt → 56pt）**。基线实测（`r19-retro-baseline.png`，像素级）：
600×796pt 窗、空态内容墨迹止于 264pt、下方 **532pt 纯背景**（比 §88 记录的还大——
当年的「约 530pt/270pt」是像素当点数读的）。修法是窗口按状态定尺寸：

- 空态（打开时没有已完成回顾）→ 内容高 **320pt**（264 实测 + 呼吸）；
  有报告 → **796pt**（r20 证明该高度下报告免滚动；更长的报告走 resultView 的
  ScrollView，不设更高的地板）。
- 首次生成落地（`.retrospectiveLiveUpdate`）且窗口还在未动过的空态尺寸时，
  一次性长到 796pt。**只在报告真实存在时长**——该通知对任何 run 表写入都发
  （含找不到任何东西的 reap），只看高度的旧判据会把空窗长成不存在的报告。
- `minSize` 高度 500 → 320（空态默认值可达）；宽度保持出货的 600 不动。

**踩到的机制坑（两次量出 796 才逼出来）**：`NSHostingController` 挂上
`contentViewController` 后会**持续按 fitting 尺寸追改窗口**，而这棵树的
`maxHeight: .infinity` 让 fitting 恒报 796pt——同步 `setContentSize` 写完就被
异步覆盖，画出来是「新尺寸的旧意图」。根治是 `hostingController.sizingOptions = []`
（只关「视图→窗口」的反向定尺寸，窗口手动缩放时视图照常铺满）。像素对照一锤定音：
改前/改后的**内容墨迹同在 528px 行**（内容零变化），画布 1592→640（只砍死区），
且 640 这个高度只有新构建才画得出（旧帧必为 1592——尺寸即新鲜度 oracle）。

**§136 验证**：`swift build` 通过；受影响套件（RelativeTime|Retrospective|
ChromeMotion|Companion|Admission）210 条 / 3 skip / 0 失败（真实退出码）；
像素证据 `r19-tasks-window-copy.png` / `r19-retro-baseline.png` / `r19-retro-fixed.png`
（1200×640，死区 56pt）。全量与 release 见下。

**§136 收口数字**：全量 `swift test` exit 0 —— XCTest 2300 条 / 10 skip / 0 失败
（禁语扩展在原用例内，不增条数），swift-testing 全过；`swift build -c release` 零警告。

### §137 §86 第 4 条收口：「按消息量 TOP 5」不再虚报（emil 标准轮 12，2026-09-22）

§83 记的「标签承诺的是上限不是数量，读起来像缺了 3 条」——措辞策略取
「不足 5 条时写实际数量」（§83 的选项 2），且与兄弟节同构（趋势指标/时间节奏/
压力信号的摘要全是计数插值，这节是唯一写死的）：

- `InsightOverviewCounts.topChatsSummary(shown:)` → 「按消息量前 \(n)」，一种形状
  管所有数量（2 条时「前 2」，5 条封顶时「前 5」），行数取自渲染同一个
  `shown` 数组的 `.count`——标签与行由构造保证相等，不存在第二个数字源。
- 调用点钉桩 `testTopChatsSectionFeedsTheRowCountFromTheCallSite`（§10 的教训：
  回归在调用点）：禁「TOP 5」字面量 + 必须走构造器。门禁被我自己引用旧文案的
  注释绊了一跤（§27 同款），按既有规则改成跳过 `//` 行——解释性散文必须有权
  点名被禁词。

**像素证据**（`r19-topchats-summary.png`，一帧闭环）：「最活跃聊天 · 按消息量前 2」
与正好 2 行（项目协作群 96 条 / 林晓 42 条）同框互证；上下文帧
`r19-topchats-context.png`（KPI + 时间节奏 + 关系分布 + 工作/生活）。新鲜度判据
再添一条硬的：**「按消息量前 2」这个措辞只有新构建才画得出来，旧帧必是「TOP 5」
——文案修复自带新鲜度 oracle**，比同步时间还硬。

**取证杂记**：`--preview-insight-overview` 是「把洞察页停在总览」的停靠开关，
不是导航——不带 `--preview-tab=insight` 会落在持久化的旧 tab 上（第一张就拍歪到
待办页）。滚动偏移 1750 见节头、1950 节头带行数。

**§137 收口数字**：`swift build` 通过；受影响套件（CrossTopicRadar|Insight|ProductWorkspace）
141 条 / 0 失败；全量 `swift test` exit 0 —— XCTest **2302 条 / 10 skip / 0 失败**
（净增 2 = 构造器断言 + 调用点钉桩），swift-testing 全过；`swift build -c release` 零警告。

### §138 §86 第 3 条收口：「近期」钉成按天直方图，KPI 恢复实测比较（emil 标准轮 13，2026-09-22）

**口径落定：「近期」= 按天直方图的 7 个日桶（今天 + 前 6 天）**。`InsightRecentWindow.cutoff()`
从滚动 168 小时（`now - 7×86400`）改为**日历对齐**（今天零点往前 6 天）：

- 屏幕上写「近 7 天」，读者就是掰着日历数的——滚动窗口一周里会悄悄漂掉一天；
- 「日均」只有当分子的跨度正好是那 7 天时，才是任何人能想象的「一天的量」。
- 逐条时间戳 ≥ cutoff 的计数（WeChatReader:1871，分片相加）就是 7 个日桶之和，
  单一 cutoff 源的架构不变（ChatInsightModels 的 doc 保留了那条「一个地方算 cutoff、
  另一个地方写 /7」的教训）。日界稳定性有边界测试（同一天内 cutoff 不漂移）。

**「消息总量」KPI 文案恢复实测比较**。§81 把「-100% 近期偏闲」降级成纯方向词是对的——
当时的分子是坏的（会话整段历史被计入）；现在分子就是日桶本身，诚实的动作是
**照实陈述两个日均**（§78 的陈述口径），判定交给状态点：

- `GlobalOverview` 增 `recentDailyAvg` / `overallDailyAvg`（与 ratio 同生同 nil：7 天及
  以下的窗口没有第二个跨度可比）。
- `densityHint` → 「近期日均 4.9 · 窗口日均 4.6」（`InsightKPIGrid.densityHint` 提为
  static 供测试断言字面）。不再有百分比——也就没有 -100% 那种「格式能说出的最狠的话
  用在最安静的一周上」的地板戏剧。方向词退场：两个数字的大小关系就是方向，
  红橙绿点就是判定。
- 「无法比较」的 nil 态保留原句（窗口 ≤7 天说没有比较，不冒充 节奏正常）。

**证据**（`r19-kpi-density.png` 一帧）：消息总量 138 /「近期日均 4.9 · 窗口日均 4.6」
（夹具算术互洽：recent = Σtotal/4 = 34 → 34/7≈4.9；138/30 = 4.6），同帧可见
承诺履约「—/还没有承诺记录」、VIP「0 条 / 共 138 条」、最活跃聊天「按消息量前 2」等
前几轮修复。新措辞本身就是新鲜度 oracle（旧帧只有方向词）。

**§138 验证**：`swift build` 通过；受影响套件（InsightDensity|CrossTopicRadar|Insight|
ChatInsight）109 条 / 0 失败（真实退出码），新增 3 例：日桶日界边界、双日均字面断言
（含 42.9 一位小数与整数两种形状）、nil 态不打分。全量与 release 见下。

**§138 收口数字**：全量 `swift test` exit 0 —— XCTest **2305 条 / 10 skip / 0 失败**
（净增 3 = 日桶边界 + 双日均字面 + nil 态），swift-testing 全过；`swift build -c release`
零警告。（`GlobalOverview` 增两字段令 `InsightRadarTests.makeOverview` 手搓构造同步
补参，0/1 与原 ratio:0 自洽。）

### §139 大字号档全页复核 + 723 处硬编码字号全量收口（emil 标准轮 14，2026-09-23）

**全页像素复核（--preview-large-type）**：今天页 def↔lg 仅 8.2% 像素变化、关注谁 5.6%
——未跟随 Dynamic Type 的硬编码字号占绝对主导。源码盘点同结论：`.font(.system(size:`
**726 处**（45+ 个文件，DailyReport 64、SyncSettings 56、ChatInsight 51…）对
`companionFont` 家族 106 处。任务 #10 的「逐像素不变」是整页版病灶，根因就在这 726。

**收口：723 处机械转换为 `companionFont`**（默认档 factor=1.0 逐参数等值——零默认回归
是转换的前提），仅两类保留硬写：

1. `CompanionScaledFont` 自己（Scaler 是全 App 唯一有权造字体的地方）；
2. 压缩条的装饰点符（`markSize` 8pt / `quietMarkSize` 6pt 的 ● 圆点——不是文字，
   缩放会顶出 32pt 岛条）。顺带堵上 `isWorkspace ? 12 : 9` 这类 ternary 藏的 sub-10
   可读字号——字面量门禁扫不到 ternary，转换后走 companionFont 的 10pt 地板。

`companionFont` 增 `design:` 透传（14 处 `.monospaced`/`.rounded` 因无此参数而长期
硬编码）；`.default` 保持原有两参调用形状（实测三参形状影响 <75px，但保留旧形状零成本）。

**回归网**：渲染套件全绿（AdmissionSettingsRender/IslandTypeScale/
CompanionAccessibilityRender/RenderProbe/ScrollEdgeRender/WorkspacePageLaunchSurvival）
—— 默认档像素回归的判据是这批阈值断言。app 捕获对质给出默认档 0.14%（7321px）
散布式抗锯齿微差：转换处从无字重参数的 `.system(size:)` 改走显式 `.regular` 路径，
字号/度量/布局未变（同一画布、行带位置一致）。

**增长铁证（确定性通道）**：`testConvertedBodyTextGrowsWithTheTypeScale`
（IslandTypeScaleTests）——正文 12pt 在 .large→.accessibility2 高宽均涨 >1.35×
（1.48 名义值）；`testNoHardcodedFontSizesOutsideTheMarks`（ChromeMotionHygiene）
钉住全库不再出现硬编码字号（注释行免禁、点符豁免）。§86 任务 #10 的单页门禁
（ConversationDetailView）由后者全库化取代。

**取证杂记（这轮的坑密度再创新高，判据都记下）**：
- zsh 无引号变量**不做分词**——批量循环里 `$flags` 整串成一个参数，四次裸启动拍了同一状态。
  循环式批量截图不可用，单发+启动日志（`launch tab X -> X`）逐张核。
- 「上次同步」是**持久值**（`reloadAIData` 会覆盖 seed 的 now），不是启动时刻——
  §135 写的「同步=启动时刻铁证」言过其实，撤回该表述；可靠 oracle 是**新措辞本身**
  （旧构建画不出新文案）与启动日志。
- 读图通道两度端错视觉（retro-fixed2、after2-lg），盘上文件经 md5/sips/PIL 对质无误——
  数字对质为准，视觉为辅。
- 三参 `design: .default` 假说被 7246→7321 的实测证伪，注释按 §71 规则改为实测陈述。

**新发现（非本轮引入，在案）**：`AutopilotGuardrailPipelineTests` 7 例（14 断言）
**看表失败**——「深夜静默模式（23:00-7:00）」闸门无条件读墙钟，凌晨 05:17 全量跑时
集体跳过自动发送导致断言落空；字号转换零关联（失败全在 Services 护栏链路，渲染/
排版套件全绿）。应注入时钟（照 `BriefingFreshnessTests` 的 `now` 先例），下轮处理。

**§139 收口数字**：`swift build` 通过；受影响套件（IslandTypeScale|ChromeMotionHygiene）
31 条 / 0 失败（含 2 条新增）；全量 `swift test` 2307 条 / 10 skip / **14 失败——
全部是上文所述 AutopilotGuardrailPipelineTests 的夜间窗口看表失败**（05:4x 落在
23:00-7:00 内；同一批用例在 §138 的 22:3x 全量里 0 失败），渲染/排版/文案面零失败；
`swift build -c release` 零警告。

### §140 看表缺陷根治 + §46 窄窗复检抓到「全部」再截（emil 标准轮 15，2026-09-23）

**一、§139 在案的夜间看表缺陷已根治**。`AutopilotService.processBatch` 的深夜静默闸门
直读 `Date()`，`AutopilotGuardrailPipelineTests` 7 例在 23:00-7:00 集体被闸门吞掉批次
而失败（且该闸门**零直接测试**）。修法照仓库的显式 `now:` 注入惯例：

- `handleNewMessages` / `testingProcessBatch` / `processBatch` 贯穿 `now: Date = Date()`
  （生产调用零改动）；闸门改读 `now`。顺带改名两个遮蔽参数的单调钟局部
  （`let now = monotonic()` → `mono`，批处理计时器与墙钟是两回事）。
- 13 处测试调用钉 `now: Self.daytime`（14:30）；**新增 `testLateNightSilenceHoldsThe
  BatchOnTheRealPath`**（钉 03:00）：批到 .skipped、理由含「深夜静默模式」、队列为空——
  闸门从「误伤测试的隐性依赖」变成两侧都有钉的行为。
- **当场自证**：修复后即在凌晨 06 时档跑全套 —— 该套件 20 条 0 失败（此前同档 14 败），
  全量 `swift test` **2308 条 / 10 skip / 0 失败（exit 0）**，验收信号恢复真实。

**二、§46 窄窗 <800pt 复检抓到真缺陷：大字号 × 窄窗下「全部」再截**。堆叠分支
（`ChatInsightView` <800pt：列表固定 190pt 在上、仪表盘在下）逐像素走查：
右缘 x=1518 处 y712-730 有**两枚被拦腰截断的汉字笔画**（逐像素位图存档），
默认档为 0。证伪链三次出手：

1. `densityHint` 单字符化 → 贴边**不变**（§138 的文案排除）；
2. `ViewThatFits` 图例改动前后像素差仅 250px（全在状态栏时间戳）→ 图例测量显示
   放得下、不是它；
3. 整个 `InsightKPIGrid` 摘除 → 贴边**依旧**（KPI 网格排除）。

几何终审锁定 `overviewHeader` 的选择器行：`.frame(width: 280/140)` 是**固定点宽**，
而分段选择器的内容 ×1.48；尾部块 `.fixedSize()` 后理想宽超出内容列
（760pt 窗 −236 侧栏 ≈ 524pt 对 560pt+），溢出内边距、在窗边截断末段「全部」——
与 §77 同元素同形状（当年注释自己就写着「『全部』被右边界从中间裁断」）。
默认档恰好卡进 492pt（差值 0-2pt），大字号必然爆。

**根修**：`CompanionScaledWidth`（`companionFont` 的宽度孪生——固定 chrome 宽度随
`CompanionTypeScale.factor` 缩放；点击热区方块保持固定是刻意的），头部两个选择器
`.frame(width:)` → `.companionScaledWidth(...)`。**像素定音**：贴边行
[712…730] → **[]**（x-2 与 x-5 双探针均归零），`r20-narrow-760-lg-final.png` 对
`r20-narrow-760-lg.png`。同窗默认档复核零变化（factor 1.0 逐参数等值）。

**取证杂记**：读图通道本轮彻底拒读（连工作区文件都报不存在），全程用逐像素位图 +
ASCII 墨迹图 + AX 审计（`--preview-hig-audit` 的 screen 坐标 + 滚动外元素帧）替代——
「全部」的 AX 右缘 752-760pt 恰在裁切线，数字证据比视觉更快到位。二分实验
（单字符化/摘网格）各 ~90 秒一次，证伪链比顺藤摸瓜便宜。

**§140 收口数字**：`swift build` 通过；`swift build -c release` 零警告；
全量 `swift test` **2308 条 / 10 skip / 0 失败（exit 0）**——含新增夜间闸门用例、
在 §139 的失败时段（凌晨档）实测通过；护栏套件 20 条 / 0 失败。

### §141 全量判定收口「固定宽装缩放内容」病灶（emil 标准轮 16，2026-09-23）

遍历 Sources 全部 **188 处 `.frame(width:)`**，逐个判定（判定表如下），**25 处内容框
换 `companionScaledWidth`**（新增 `alignment:` 参数——标签列的左/右对齐不能丢），其余 163 处
按豁免留固定：

| 类别 | 处置 | 例 |
|---|---|---|
| 点击热区方块 / 图标槽 | **豁免**（HIG 热区是固定命中尺寸） | 22×22、24×22、28×28、`inlineIconTarget` |
| 点符 / 徽标点 | **豁免**（装饰非文字，缩放会顶出 32pt 岛条） | 5×5、6×6、8×8、markSize |
| 岛体硬件几何 | **豁免**（ui-language：硬件几何不参与插值） | wingWidth、peekSlotWidth、bannerWidth、expandedWidth |
| 图表几何 | **豁免**（图形不是内容框） | 柱条 `width: geo*fraction`、滑轨 120、进度条 90、迷你条 60×6/80×8 |
| 画布网格 / 弹窗表面 / 渲染夹具 | **豁免** | PixelBuddy cellSize、对话框 380/460、ImageRenderer 380×420 |
| 会换行的文字列 / 栏目列 | **豁免**（文字自行折行、不被挤出） | 今天页 280pt 接下来栏、SetupCard 24pt 图标列 |
| **装不可换行内容的固定宽** | **→ `companionScaledWidth`** | 分段/菜单选择器 ×9、单行值列 ×6、标签列 ×7、DatePicker/统计方块/贪睡浮层/引导状态块 ×4 |

病灶 25 处明细：选择器 9（AI 服务来源 220、展示时间 100、同步间隔 92/缓存 90/屏幕 110、
回复风格 140、每小时 80、连发 80、发送键 170）、Menu 标签 70、值列 6（42/28/60/40/…）、
标签列 7（88/52×2/58/34/28/30）、`ChatInsightDetailView` 统计方块 80×80（即上轮点名的
「`frame(width: 80)`」——同文件另一处 80×8 是条形轨道属豁免，判定表落锤）、
回顾日期 DatePicker 120、贪睡浮层 220、引导状态块 140。

**像素证据**（`r21-autopilot-lg-before/after.png`、`r21-detail-lg-before/after.png`）：
自动回复页表单区差 **40,498 px**（选择器行加宽落位）、会话详情差 **227,632 px**
（统计方块 80→118、图例列、DatePicker 加宽）；四图右缘贴边墨迹**全净**
（改前改后均 []——这批站点此前是「挤出/截断内部文字」型病灶，不是贴边型，两型都归零）。
默认档零回归由全量 **2308 条 / 0 失败（exit 0）** 的渲染网背书：factor 1.0 时
`companionScaledWidth(N, alignment:)` 与原 `.frame(width: N, alignment:)` 逐参数等值。

**取证杂记**：两个截图并行跑会互相 rm `$T` 产物（wcsnap4 每次清场）——本轮开场就丢了一张，
串行重拍；另 Bash 的 cwd 会跨调话筒残留（早前 `cd Sources/WeChatHUD` 让相对路径 cp 找不到
目标），一律绝对路径。

**§141 收口数字**：`swift build` 通过；`swift build -c release` 零警告；全量
`swift test` **2308 条 / 10 skip / 0 失败（exit 0）**；受影响套件 474 条 / 0 失败。

### §142 窄窗 × 大字号逐页复检（emil 标准轮 17，2026-09-23）：10 页干净、待办页一处布局振荡病灶

**复检面（11 页全过 §140/§141 双判据）**：今天、待办 + 设置九分区（关注谁/AI 分析与建议/
提醒方式/AI 服务/自动回复/微信连接/使用偏好/本地资料/怎么用），全部 760pt × accessibility2。
四锚点全景表（侧栏顶墨迹 / detail 页头墨迹 / 状态条墨迹起止 / 底缘贴边计数）：

| 页面 | 侧栏顶 | 页头 | 状态条 | 底缘 |
|---|---|---|---|---|
| 9 个设置页 + 今天 + 怎么用 | 32 | 49（怎么用 66，无页头属正常） | 1810–1842 | **0** |
| **待办（4 次捕获全同）** | **0** | **23** | **1853–1867（贴底裁切）** | **150px** |

**待办页病灶（未修，见下）**：窄窗 × 大字号下内容列整体高于窗体约 34pt——页头上移 13pt、
状态条下压 21pt（居中溢出签名）、侧栏锁图标贴顶截断、页脚被顶出窗底、底缘 150px 贴边墨迹。
跨 3 次构建 4 次捕获逐锚点完全一致（确定性成立，非捕获瞬态）。

**机制追查（两轮仪器实测）**：
1. 窗几何两页**完全相同**（760×934 content / 760×986 含标题栏）——窗口尺寸层排除；
2. 待办根视图**宽度稳定 424pt、高度在 603 ↔ 872.5 间循环振荡**（同宽下高度反复跳、
   每轮 layout pass 互相触发成环）；溢出帧 = 872.5 > 830 可用高。
3. **病灶定性 = 高度反馈式 relayout 振荡器**（某块的尺寸依赖其收到的 proposal，回写成环）。
   待办链上带 proposal 敏感构造：filters 的 `ViewThatFits` 双行胶囊回退（±35pt 正好是
   34pt 溢出量级）、`HSplitView`（NSSplitView 内禀理想高）、detailPane 的
   `fixedSize(vertical: true)` 文本群。其余 10 页无此组合故全净。

**证伪记录（两处假修复已按 §66 撤除，树回到 §141 已验证态）**：
1. 页脚 `minimumScaleFactor(0.75)` 测量失真说 —— 摘除后四锚点逐值不变，**证伪**，已恢复原样；
2. `HSplitView` 加 `.frame(minHeight: 0, maxHeight: .infinity)` —— 锚点逐值不变
   （frame 不缩子级 min，NSSplitView 内禀照旧），**证伪**，已撤。
临时量测仪器（`onGeometryChange` 两行 + capture 一行打印）用完即撤。

**已定价选项（按 AGENTS「两次修复失败→停手带选项上报」）**：
- **A. 捉振荡边（推荐先做）**：在 listPane/detailPane/filters 三处加 per-pass 提案-实高打印，
  找到回写边（预计 1–2h），修复本身大概率一行（断开 proposal→height 的反馈）；
  风险：侦探工作量不确定，但产品改动极小。
- **B. 结构性去振**：filters 的 `ViewThatFits` 换成确定性换行 Layout、`HSplitView` 换
  `HStack + Divider` 固定比例（约半日）；风险：filters 是 §11/§12 崩溃旧地，
  但 `WorkspacePageLaunchSurvivalTests` 兜底。
- **C. 美观止血（不治本）**：SettingsView 层把内容列溢出钳住（页头/状态条不再被顶走，
  约 1h）；风险：振荡回路继续空转 CPU，只是看不见。

**§142 收口数字**：证伪回滚后 `swift build` 通过、`swift build -c release` 零警告、
全量 `swift test` **2308 条 / 10 skip / 0 失败（exit 0）**（树与 §141 收口态一致，
本轮产品代码净变化为零——这正是「不留假修复」的代价与目的）。证据：
`r22-nlg-{today,tasks,contacts,aiButler,notifications,aiService,autopilot,system,preferences,localData,guide}.png`
11 张 + `r22-nlg-tasks-{fixed,fixed2}.png` 证伪帧 2 张。

### §143 选项 A 侦破轮（emil 标准轮 18，2026-09-23）：病灶测量链闭合、五次修复全部证伪、停手升级

**测量链（全部实测，树 dump 双采样 0.6s 相邻一致 = 收敛态，无振荡——§142 的「振荡」表述
修正为「多轮 settle 走查」）**：

| 量 | 待办（窄窗×大字号） | 今天（同参数） |
|---|---|---|
| 根宿主 frame | **760×977** | 760×934 |
| 根宿主 fitting（理想） | **605×977** | 424×**182** |
| 窗口 content | 760×934 | 760×934 |

**病灶定性（比 §142 更准）**：待办链的内容**理想高 977**（页头 70 + 内容 874 + 状态条 33）
把 NavigationSplitView 的 AppKit 内禀理想顶出，representable 的 ideal 压过 proposal，
934 窗体溢出 43pt。特征性怪相：`_NSSplitViewItemViewWrapper` 的 **fitting 回声 frame**
（fitting==frame 自指），且 ScrollView 节点 fitting=0、子树无一 ≥400——理想不在叶子、
在 representable 接缝上「爬回来」，这解释了为何 SwiftUI 侧逐点杀理想都动不了 frame。

**五次修复全部证伪（树已按 §66 撤净，产品代码净变化为零）**：
1. 页脚 `minimumScaleFactor` 摘除 —— 锚点逐值不变，证伪（§142 已录）；
2. `HSplitView` 加 `frame(minHeight:0, maxHeight:.infinity)` —— 无效（frame 不缩子级 min）；
3. detailPane ScrollView 内 `Spacer(minLength:12)` 删除 —— 仅削 11px 边缘墨（151→140），
   全局位移不动，证伪；
4. 内层 `GeometryReader` 包任务 HSplitView —— split fitting 确实坍缩到 16，
   但根理想 977 依旧（经 NSSplitView fitting 回声爬回），无效果；
5. **根 `GeometryReader` 包 SettingsView** —— 侧栏顶/底缘干净了（32 / 0），**但状态条与
   侧栏页脚被裁出画布**（底带左半墨迹 0 对今天 108px）——以藏尾换边缘净 = 回归，撤。

**已定价选项（第二次升级，AGENTS「两次以上失败→停手上报」）**：
- **D. 换掉 tasks 的 `HSplitView`（推荐）**：换成纯 SwiftUI 双栏（`HStack + Divider` 或
  自绘分隔），消灭 fitting 回声的来源（AppKit representable）——这是被点名的接缝本体。
  估 2–4h（分隔条拖拽交互需以 `Divider + 手势`重建或有意识放弃）；净
  `WorkspacePageLaunchSurvivalTests` + 本轮锚点表回归。
- **E. 压 detailPane 内容理想**：检查器栈（594pt fixedSize 文本群）改可折行/去掉
  `fixedSize(vertical:)` 级联——治源头但理想回声可能仍在（同 4 的教训）。估 1–2h，效果存疑。
- **F. SettingsView 层显式分高**：`content` 用 GeometryReader 取「窗高−页头−状态条」
  显式 frame（chrome 永不被顶走，内容内部滚动）——治标不治本但用户可见行为全对。
  估 1h，风险低；注意与选项 5 的区别：包 `content` 而非整根，chrome 不在裁切面内。

推荐 **D**（治本于被点名的接缝）+ 验收锚点表（32/49/1810/0 那一行）为完成判据。

**§143 收口数字**：撤净后 `swift build` 通过、`swift build -c release` 零警告、
全量 `swift test` **2308 条 / 10 skip / 0 失败（exit 0）**——树与 §141 收口态一致。
本轮证据：`r23-tasks-{oscfix,geofix,rootfix}.png` 三张证伪帧 + 树 dump 数据（tree*.log
留在 /tmp，关键数已录于上表）。

### §144 选项 D 执行轮（emil 标准轮 19，2026-09-23）：representable 接缝已灭、残余隔离至 strictnessBar

**选项 D 已执行**：待办页 `HSplitView`（NSSplitView representable、fitting 回声源）
整块换成**纯 SwiftUI 双栏**——`GeometryReader + HStack(55/45) + Divider`，
分隔条拖拽按选项 D 定价**有意识放弃**（固定比例换取任意宽度/字号下永不溢出）。
`strictnessBinding` 因改造失去全部引用，按孤儿规则清除。

**D 自身交付物已验证**：二分链里「摘 strictnessBar、保留双栏新布局」一测达到**全锚点健康
（32/66/0）**——split 不再贡献任何理想（此前它至少占 594pt 回声）。`WorkspacePageLaunchSurvivalTests`
（tasks 最小宽实跑）2308 条全量绿 = 改造的存活网。

**残余病灶精确隔离（二分链全程实测）**：

| 状态 | sideTop | detHead | botEdge |
|---|---|---|---|
| 健康参考（今天 / 摘 strictnessBar） | 32 | 51 / 66 | 0 |
| filters 全量（含 strictnessBar） | 0 | 23 | 151 |
| strictnessBar 内 Picker→单行占位文本 | 9 | 43 | 0 |
| strictnessBar 内 Picker→pills 家族（本轮落地） | 0 | 19 | **115** |

- `filters` 内其余成员（ViewThatFits 双行胶囊、搜索、说明文本）**全部排除**（摘
  strictnessBar 即全正常）；「双计」假说排除（strictnessBar/filters 各仅一处引用）。
- 分段 Picker 是**主源**：换成单行文本即从 151→0 底缘、位移消 2/3。
- pills 化（本轮产品改动）：底缘 **151→115**（实测部分有效）、与 scopePills 视觉家族统一；
  残余 ~11.5pt 幽灵理想在 strictnessBar 其余成分（保留标签/展开按钮/padding/
  `fixedSize(vertical:)` 说明文本的组合）。
- **6 秒延迟捕获复测同态**（0/…/116）= 稳定错理想，非慢收敛（排除「捕获抓在 settle 中途」）。

**完成判据核对（诚实记录）**：锚点表 **32/49/1810/0 未达成**——现状 0/19/1867/115，
较改前（0/23/1867/151）部分改善但未归位。选项 D 的点名目标（消灭 representable 接缝）
**已达成并验证**；溢出的最终源头经二分落在 strictnessBar 的组合件上。

**选项 G（下一刀，已定价）**：
- **G1. 吃掉 strictnessBar 残余（推荐）**：按二分法对 bar 内剩余四件逐一摘测（说明文本的
  `fixedSize(vertical:)` / 展开按钮 / 保留标签 / padding 组合），找到那 11.5pt 的幽灵理想
  并断掉——**估 1–2h**（二分循环每刀 2 分钟，机制清楚后修复大概率一行）。
- **G2. 止血钳（可与 G1 并行）**：选项 F 的 content 显式分高，chrome 永不被顶走——
  估 1h，用户可见行为即刻正确，G1 落地后可留可撤。

**§144 收口数字**：`swift build` 零警告；`swift build -c release` 零警告；全量
`swift test` **2308 条 / 10 skip / 0 失败（exit 0）**。证据：`r24-tasks-{twopane,pills}.png`、
`r22-nlg-tasks.png`（改前）对照 + 四态锚点表（上）。

### §145 选项 G1 终局（emil 标准轮 20，2026-09-23）：幽灵理想正身 = `fixedSize(vertical:)`，四锚点全归位

**根因（单变量归因闭合）**：`strictnessBar` 说明文本上的
`Text(strictness.explanation).fixedSize(horizontal: false, vertical: true)`——
这**一个修饰符**就是 §142 全部溢出的幽灵理想源。归因两刀：

- B1：说明文本换占位（无 fixedSize）→ 全锚点健康（32/66/1809-1842/0）；
- **B1b：恢复原文、仅去 `fixedSize`** → 同样全健康（同文归因 ✓ 内容无关，纯修饰符之过）。

机制：`fixedSize(vertical: true)` 让文本的理想高度脱离提议自报，而 AppKit fitting 搜索
（无约束宽）与渲染宽（404pt 三行）下它反复报不同高度——正是 §143 测到的 977 幽灵理想的
制造者。文本本就按行数取全高，删掉它渲染语义零变化。原写法（如同文件 §534 注释警告过
的形状）属历史残留。

**终局锚点表（完成判据 32/49/1810/0 归位）**：

| 帧 | sideTop | detHead | status | botEdge | leftEdge |
|---|---|---|---|---|---|
| 改前（r22-nlg-tasks） | 0 | 23 | 1756–1867 | 151 | 0 |
| **判据页（r25-tasks-ghostfix）** | **32** | **66** | **1809–1842** | **0** | 0 |
| 回归 今天（r25-today-regression） | 32 | 51 | 1750–1842 | 0 | 0 |
| 回归 自动回复（r25-autopilot-regression） | 32 | 49 | 1809–1842 | 0 | 0 |

（detHead 49/51/66 为各页页头自然位；status 1809–1842 与 1810–1842 同健康档；四缘全净。）

**归因更正（§71 纪律）**：§144 把幽灵理想的 2/3 记在「分段 Picker」名下是**混杂变量误判**
（摘 Picker 时顺带压缩了整条 row 的布局宽度，fixedSize 文本的折行态随之改变）；
单变量重判后正身是 fixedSize。pills 化**保留**（与 scopePills 控件家族统一，注释已改为
终局口径），Picker 归因句已改写不留错误机制。

**六轮小史（一并收档）**：§142 发现病灶并定性（含「振荡」表述的后修正）→ §143 五次修复
证伪 + 定价选项 → §144 选项 D 执行（HSplitView→纯 SwiftUI 双栏、representable 接缝消灭、
pills 化）+ 二分隔离 → §145 选项 G1 一刀归因、判据归位。全程教训：**同一症状的多因混杂
必须单变量归因**（六次「无效/部分有效」的修复里有五次是被混杂变量带偏的假线索）。

**§145 收口数字**：`swift build` 零警告；`swift build -c release` 零警告；全量
`swift test` **2308 条 / 10 skip / 0 失败（exit 0）**。证据：`r25-tasks-ghostfix.png`
（判据页）+ `r25-{today,autopilot}-regression.png`（回归对照）+ 终局锚点表（上）。
在案遗留仅剩：证据目录归档/清理（等用户定夺）。

### §146 证据目录归档执行轮（2026-09-23）：零损归档已落、删除项待定夺

**盘点（保守口径）**：目录 `2026-09-18-island-pixel/` 共 **732 张 / 255MB**。
引用检测取保守口径（QA 文档 `docs/qa/*.md` 精确点名 + 花括号缩写 `{a,b}` 展开 +
`前缀-*` 通配一律算引用，避免 §142「r22-nlg-{…} 11 张」这类缩写误伤）：

- **保留 99 张 / 64MB**（QA 引用证据，含各轮对照帧）
- **清理候选 633 张 / 191MB**（auto/auto2 双份帧、失败尝试帧、早期 h*/n*/set-* 系列）

**已执行（零损、可逆）**：
1. `2026-09-18-island-pixel/MANIFEST.md`——732 行全量清单（文件/大小/md5(12)/保留-候选），
   任何未来清理都有据可依；
2. 候选 633 张打包 `docs/qa/archives/2026-09-18-island-pixel-uncited-20260923.tar.gz`
   （**161MB**，gzip 省 16%——PNG 本身已压缩，「压缩」杠杆有限，核心杠杆是删未引用），
   已 gitignore（`docs/qa/archives/`）防入版本库；
3. **归档完整性验证**：包内 633 张齐全；抽检解压 2/2 与原图 md5 逐字节一致
   （该包是未来删除的唯一恢复源，必须先证明完好）。
4. **原图 732 张全部原地保留**——目录未入 git（`git ls-files` 为 0），删除即永久丢失，
   按边界规则未获确认不执行删除。

**待定夺（已发选项、未获答复，未臆造偏好）**——删除这一步仅需你一句话：
- **B（推荐）**：删 633 张候选原图（归档包已在 `docs/qa/archives/`，可随时解压恢复）
  → 目录 255→64MB。执行命令即 `python3` 按 MANIFEST 的「候选」分类删图，或我下轮执行。
- **A**：什么都不删（现状即归档态），255MB 维持。
- **D**：删候选且连归档包不留（不可逆最重，释放 191MB+161MB）。

**§146 收口数字**：归档包 161MB / 633 文件 / 抽检 2/2 完好；MANIFEST 732 行；
产品代码零改动（本轮纯证据治理，无需重跑套件；上轮基线仍为全量 2308 条 / 0 失败 exit 0）。

### §147 窄窗 × 大字号全页复检收官（emil 标准轮 21，2026-09-23）：17/17 过完、零新缺陷

§142 的 11 页之外，本轮补齐其余 6 个工作台页（草稿 / 会话详情 / 今日小结 / 关系雷达 /
待确认回复 / 洞察总览-全展开），**四锚点 + 三缘全绿**：

| 页面 | sideTop | detHead | status | bot | left | right |
|---|---|---|---|---|---|---|
| 草稿 | 32 | 53 | 1809–1842 | 0 | 0 | 0 |
| 会话详情 | 32 | 51 | 1809–1842 | 0 | 0 | 0 |
| 今日小结 | 32 | 49 | 1809–1842 | 0 | 0 | 0 |
| 关系雷达 | 32 | 49 | 1809–1842 | 0 | 0 | 0 |
| 待确认回复 | 32 | 49 | 1809–1842 | 0 | 0 | 0 |
| 洞察总览 | 32 | 51 | 1809–1842 | 0 | 0 | 0 |

**全页复检正式收官**：17 页（今天 / 待办 / 草稿 / 会话详情 / 今日小结 / 关系雷达 /
待确认回复 / 洞察总览 / 设置九分区）在 窄窗 760pt × 大字号（accessibility2）下
**16 页原生健康、1 页（待办）病灶已于 §145 根修后归位**——本轮 6 页零新缺陷。

复检方法即 §145 的战利品：四锚点表（侧栏顶 32 / 页头 49-66 / 状态条 1809-1842 / 底缘 0）
+ 三缘贴边扫描，幽灵理想类病灶（`fixedSize(vertical:)`、AppKit representable 内禀）
一量即现。至此「大字号 × 窄窗」这个压力组合在全部页面验证完毕，方法与判据已沉淀为
可复跑的量测口径。

**§147 收口数字**：本轮纯取证（产品代码零改动），§145 基线仍有效（全量 2308 条 /
0 失败 exit 0、release 零警告）。证据 `r27-nlg-{drafts,insight-detail,dailyReport,
relationshipRadar,autopilotDashboard,overview}.png` 六张 + 上表。
悬置项不变：证据目录删除结论（「按 B 删」/「按 D 彻底清」/「不删」）待用户一句话。

### §148 深色 × 窄窗 × 大字号全页复检（emil 标准轮 22，2026-09-23）：17/17 几何全绿、零新缺陷

17 页矩阵的浅色档（§142/§147）之外，补齐**深色档**同参数（760pt × accessibility2）。
扫描器改「底色偏离法」（|luma − 角落底色| > 45/30）双主题通吃。**sideTop=32 全 17 页一致**
——§145 根修的几何在深色下同样成立（几何与外观无关的预期被证实）。

三处扫描差异逐一排伪，全部为**测量噪声 / 主题级 chrome**，非缺陷：
1. `right=1` 全 17 页统一 —— 深色窗框 1px 发丝线（裁切必页面级，统一即 chrome）；
2. `status` 起点 1784（浅色 1809）全页统一 —— 深色状态条上沿发丝线被墨迹法捕捉，
   底端同样落在 1842 ✓；
3. `detHead` 三页异常值（today 86 / tasks 114 / drafts 108，其余 48–51）——
   **today 深浅两档页头墨迹轮廓逐行吻合**（54/66/84/90/102… 全同），差异纯属
   「>2 采样/行」阈值对细笔画 AA 的敏感度（同款字浅色下落在阈上、深色落在阈下）。
   排判方法沉淀：**同一区域深浅轮廓逐行对拍**，一行即判「布局异常 vs 测量噪声」。

| 维度 | 结果 |
|---|---|
| 17 页 sideTop | 全部 32 ✓ |
| 17 页 detHead | 48–51（+三页阈值噪声，轮廓对拍无异常）|
| 17 页 status | 全部 1784–1842（主题发丝线 + 底端 1842 ✓）|
| 三缘贴边 | bot=0 left=0 全页；right=1 全页统一=窗框线 |

**深色档复检收官**：窄窗 × 大字号 × {浅色, 深色} × 17 页 = 34 帧矩阵全部健康
（唯一病灶待办页已于 §145 根修、双外观归位）。方向留档：**深色档的对比度走查**
（§130 类的次级文字 WCAG 复测）可作独立轮次——本轮判据是几何（锚点/贴边），
对比度属另一判据面。

**§148 收口数字**：纯取证轮（产品代码零改动），基线仍为 §145 全量 2308 条 / 0 失败
exit 0、release 零警告。证据 `r28-nlgdark-*.png` 17 张 + 上表。悬置不变：
证据目录删除结论待用户一句话（问选两开未获答复，不臆造、不自删）。

### §149 深色档对比度走查（emil 标准轮 23，2026-09-23）：15 处抬升 + §87-4 角标删除

**判据**：token → WCAG 解析表（精确非估计；`foregroundOpacity` 默认档原样返回 nominal，
斜坡只在「提高对比度」下生效 ⇒ 深色默认档对比度=nominal 阶梯本身）：

| nominal | 黑底对比度 | 判定（小字 4.5 / 大字 3.0） |
|---|---|---|
| 0.30 | 2.46:1 | ✗✗ 不及大字线 |
| 0.35 | 3.01:1 | △ 仅大字 |
| 0.40 | 3.66:1 | △ 仅大字 |
| 0.42 | 3.95:1 | △ 仅大字（IslandInk.tertiary 档，政策认可的「时间戳/提示」档） |
| 0.45 | 4.41:1 | △ 仅大字（擦边） |
| 0.50 | **5.28:1** | ✓ 小字达标 |
| 0.55 | **6.27:1** | ✓（IslandInk.meta「用户仍需读的事实」档） |

**修复（15 处，按 §89 政策「散文字 ≥secondary、tertiary 只给 affordance」重新分层）**：
- `0.30 → 0.55`（2.46:1 全场最差）：AI 建议理由（可读正文）、引导句「点击生成建议…」；
- `0.35 → 0.55`：空态句「这段对话暂时没有本地消息。」；
- `0.35 → 0.5`：输入占位「输入回复…」、composer 状态详情句；
- `0.40 → 0.5`：「正在生成…」状态词、建议语气标签；
- `0.42 → 0.5`：发信人名/对话名（身份信息）、亮点正文、metaRow 标签列、指标标签；
- `0.45 → 0.5`：进度句「N / M 个对话」、发信人 sender 行；
- `0.35 → 0.42`：亮点时间戳（归一到 sanctioned tertiary 档，不再低于它）。
- **§87-4 闭环**：回顾窗右上角灰字「WeChatHUD」**删除**（与窗口标题重复 + 3.0:1），
  该条自 §87 挂账至今清零。像素实证：`r29-retro-no-cornermark.png` 右上角亮像素 **0**。

**报告档（不改动、留档）**：0.42 时间戳类（todoMeta 等）= 3.95:1——小字严格
WCAG AA（4.5）擦不过，但这是 §89 立档认可的「时间戳/提示」tier；全面抬升属色彩
体系决策，不在本轮顺手改。同理 IslandInk.quaternary(0.26) 只用于装饰/禁用件（合规）。

**证据**：`r29-island-detail-contrast.png`（岛详情，修复文本群所在面）、
`r29-retro-no-cornermark.png`（角标删除实证）。渲染核对：≥6:1 桶 31/38 行、
3–4.5 桶对应时间戳档，与解析表自洽；地板值 1.2:1 行为卡片表面/分隔线的探测器假阳。

**§149 收口数字**：`swift build` 零警告；`swift build -c release` 零警告；全量
`swift test` **2308 条 / 10 skip / 0 失败（exit 0）**。悬置不变：证据目录删除结论
待用户一句话（按 B / 按 D / 不删）。

### §150 归档清理执行轮（2026-09-23）：可逆部分已执行、删除决定仍待一句话

**执行口径**：「归档清理」的可逆部分 = **纯移动、零删除**（移动 ≠ 删除，不触
「删除不自主执行」红线）。按 MANIFEST 分类把 QA 未引用候选移入归档区：

| 区 | 内容 | 体积 |
|---|---|---|
| 主目录 `2026-09-18-island-pixel/` | **196 张 QA 引用证据 + MANIFEST.md** | 105MB |
| `archives/2026-09-18-island-pixel-uncited/` | **561 张候选**（原图原字节） | ~191MB |
| `archives/…uncited-20260923.tar.gz` | 移动前快照（633 张旧口径，含 72 张后被引用者） | 161MB |

**对账（757 = 196 + 561，逐张闭合）**：总数 757 = §146 时的 732 + 后续轮新增 25
（r27×6 / r28×17 / r29×2）；保留数 99→196 的增长 = §147–§149 新增小节**点名引用**
了新帧与旧对照帧（引用即保护，保守口径宁多勿动）。首轮移动漏 1 张
（`z-tasks-workspace-auto2.png`），复算分类揪出补移后逐张闭合、0 缺失 0 同名。

**待定夺（不可逆、唯一剩余决定）**：归档区 561 张与冗余快照包是否删除——
「按 B 删」（删 561 张松散候选，快照包可恢复；归档区→0）/「按 D 彻底清」
（再删 161MB 快照包，不可逆）/「不删」（全保留）。注意快照包与松散文件**内容完全重复**
（同批候选、移动前快照），其去留可独立于 B/D 单独定。

**§150 收口数字**：纯文件治理轮（产品代码零改动，§149 基线仍有效：全量 2308 条 /
0 失败 exit 0、release 零警告）。MANIFEST 已重写为终态（757 行全量台账）。

### §151 方案 B 执行轮（2026-09-23）：候选已删、悬置项闭环

用户定夺：「按你推荐处理」→ 推荐方案 = **B（删候选、快照包双保险）**。

**删除前可恢复性证明（逐名核对）**：561 张待删 ⊆ 快照包 633 张，**缺失 0**——
快照包（`archives/…uncited-20260923.tar.gz`，161MB）为唯一恢复源，完整性此前已
抽检 2/2 逐字节一致（§146）。证明通过后执行删除。

**执行与对账**：
- 561 张候选原图已删、归档区目录已移除；
- 主目录终态：**196 张 QA 引用证据 + MANIFEST**（105MB）= 恢复索引（在册 md5 全量）；
- 恢复方法一行：`tar xzf docs/qa/archives/2026-09-18-island-pixel-uncited-20260923.tar.gz`。

**执行坑记（while-read 末行）**：首轮删除 `while read` 循环漏掉无尾换行文件的最后一行
——排序末位的 `z-tasks-workspace-auto2.png` 幸存，终态对账（1 ≠ 0）当场揪出；补删前
先按名复核其在快照包内（匹配 1）再删。教训：**while-read 删清单必先补尾换行或事后
按账对数**，「删除完成」必须以对账为准而非循环跑完。

**悬置项闭环**：全会话唯一挂账项（证据目录处置）至此清零。磁盘终态：
主目录 105MB + 快照包 161MB（B 方案即保留恢复源；若日后要极致瘦身，删快照包
即 D 方案——不可逆，另议）。

**§151 收口数字**：纯文件治理轮（产品代码零改动，基线仍为 §149：全量 2308 条 /
0 失败 exit 0、release 零警告）。
