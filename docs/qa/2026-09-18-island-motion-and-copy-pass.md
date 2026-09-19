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
