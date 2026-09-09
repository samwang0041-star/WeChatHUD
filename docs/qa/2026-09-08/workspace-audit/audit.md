# 工作台、助理与偏好设置：当前界面审查

2026-09-08，本次运行即时截图。目标是普通用户能理解入口、状态和下一步。截图来自原生演示包，全部为虚构对话；未向外发布，也不作为真实AI、微信发送或首次连接通过证明。尺寸约976×768。

共同方向：保留原生侧栏、系统控件和青绿色主操作；修复信息层级、较小字体、重复入口与技术用语。截图只能提示对比度和触控目标风险，不构成完整辅助功能合规验证。

## 1. 今天

![今天](01-today.png)

现有基础：卡片可读，来源与处理按钮明确。

待改：总览数量和消息列表是两套语义；每张卡都有多个动作，需要明确主次与处理后去向。

## 2. 待办与跟进

![待办与跟进](02-tasks.png)

现有基础：支持责任筛选、来源讨论和状态操作。

待改：重复的AI说明占空间；“责任错了”表达生硬，完成前的勾选图标容易与已完成混淆。

## 3. 我的承诺

![我的承诺](03-commitments.png)

现有基础：原话、背景、下一步已有数据。

待改：重要内容使用过小字体；置信度占据主视图，完成和取消只显示图标，详情没有层次。

## 4. 回复草稿

![回复草稿](04-drafts.png)

现有基础：编辑、继续回复和删除路径存在。

待改：保存修改与继续回复都用主色；列表直接展开全部编辑器，数量增加后难以浏览。

## 5. 聊天洞察

![聊天洞察](05-insights.png)

现有基础：具备独立会话导航和时间范围。

待改：标题结构与工作台不同；嵌套侧栏挤压内容。此次演示无真实消息，仅验证空态，不能评价真实分析内容。

## 6. 每日简报

![每日简报](06-digest.png)

现有基础：保留事实整理来源和日报草稿。

待改：正文、行操作和草稿文本过小；内容像压缩浮窗，未适配工作台空间。

## 7. 关注的对话

![关注的对话](07-following.png)

现有基础：有列表、选中详情及编辑入口。

待改：暴露账号ID、扫描队列、回复债务等实现用语；名单分类需用用户能理解的含义解释。

## 8. AI设置：服务

![AI设置：服务](08-ai-settings-top.png)

现有基础：服务状态、测试和凭据配置可见。

待改：当前服务与供应商卡重复提供测试；大量连接表单把日常行为设置推到屏幕外。

## 9. AI设置：行为与提醒

![AI设置：行为与提醒](09-ai-settings-behavior.png)

现有基础：开关说明及自动保存提示已有。

待改：用户需要先越过服务配置才能设置提醒；分析、提醒、服务应各有明确入口。

## 10. 自动托管设置

![自动托管设置](10-autopilot.png)

现有基础：运行状态和限制有说明。

待改：开始操作在另一个名为记录的页面；多层开关关系依赖长段解释才能理解。

## 11. 托管记录

![托管记录](11-autopilot-history.png)

现有基础：已有开始及会话操作。

待改：名称是记录，内容却是运行控制；空态字体太小，主操作不突出。应作为回复助理的运行页。

## 12. 连接与数据

![连接与数据](12-connection.png)

现有基础：统一连接入口及实时状态可见。

待改：连接、外观、系统权限和历史导出混在同页。首次连接缺少准备材料时仍不能完成，是能力缺口。

## 13. 使用指南

![使用指南](13-guide.png)

现有基础：帮助可直接跳转设置。

待改：快速开始描述过度简化，可能让没有首次读取条件的用户误以为文件授权足够。


## 14. 改版承诺页：原生预览复验

![改版承诺页](14-commitments-redesigned.png)

2026-09-08 本轮重新构建并重启 Preview 后截图。侧栏已分为工作台、助理、偏好设置。承诺正文、对象、期限、下一步清楚分层，来源默认折叠，操作按钮有文字。实点展开来源显示原话、背景与识别依据；标记完成后进行中与侧栏计数归零，完成历史出现该项；恢复进行中后计数恢复。仅操作虚构演示数据。

仍需验收：长内容、窄窗口、键盘与深色模式；截图中次要元数据仍偏小。此证据不代表真实微信连接或发送通过。

## 15. AI 设置：提醒分区

![提醒分区](15-ai-reminder-section.png)

实点从分析与建议切换到提醒方式，只显示对应设置，当前服务和入口保留。布局完整无截断，浮窗与系统通知的作用有说明。没有切换提醒开关，没有触发 AI 请求；截图“已验证”为演示环境已有记录，不能作为本轮真实端点验证。分析页仍存在内部术语，已另行修改源代码为普通用户表达，待下次预览复验。

## 16. 回复助理：首屏仍需整改

![回复助理整改前](16-reply-assistant-before.png)

实际点击新侧栏进入运行页，路由正确。首屏主按钮仍沿用紧凑浮窗字号；说明使用“托管”“VIP”等术语，用户需要先学习设置关系；robot 图标未显示。此页不通过低教育成本验收。整改方向为明确当前发送方式、一个清楚的开始动作、直接设置入口；保留真实配置及发送限制。没有启动助理或发送消息。

## 17–18. 每日简报：日期工具栏与错配回归

![简报改版](17-daily-report-redesigned.png)

本轮重新构建的原生预览已去掉重复标题与重复统计，日期/导出/刷新操作清晰。正文动作仍有无文字图标，可复制小结默认全展开，已继续整改。

![日期内容错配](18-daily-date-mismatch.png)

从今天点击前一天，标题改为9月7日，但正文仍为9月8日小结；稍后复查无变化。此路径不通过。代码检查发现缓存快速返回未校验正在显示的报告日期，以及异步结果缺少请求身份校验；修复与回归测试进行中，不能将此截图视为日期切换通过。

日期错配复验补充：缓存日期校验和异步请求代次修复后，历史小结仍显示次日日期。进一步定位 DailyReportBuilder 把历史范围的结束边界（次日零点）传作小结标题日期，并在历史报告中使用未限制日期的当前承诺/未读/待回复状态。历史报告范围与语义修复仍在进行，不能宣称原生日期验收通过。

## 19. 回复助理首屏复验

![回复助理改版](19-reply-assistant-redesigned.png)

原生预览可见“未开始”、当前关闭自动发送、开始助理和设置入口；原失效图标已正常显示。没有启动助理，因此未验证运行队列、暂停或真实发送。本页仍需长状态文案、窄窗口、键盘和运行态的继续验收。

历史范围修复后原生复验：今天进入简报显示当前承诺；点击前一天后，当前承诺/今日进度消失，切为无来源状态，确认不再混入今天事项。空历史页仍显示“今日来源未验证”，已要求按报告日期修正文案。日报范围相关53项测试通过；尚未覆盖历史有来源页面和旧请求倒序完成的确定性调度。

## 20. 历史空记录页面最终复验

![历史空态](20-history-empty-verified.png)

本轮重新构建预览，今天可见当前承诺；切到9月7日后显示“这一天暂无可用记录”，不再混入今天承诺，也不再出现“今日来源未验证”。截图为虚构演示环境，当前窗口比先前截图宽，不能直接比较像素布局。

完整默认测试：748项XCTest（3项跳过、0失败）及70项Swift Testing（0失败），合计818项。日志 /tmp/wechathud-full-product-gate.log。跳过包括不可用live分类端点及两个需显式开启的真实AI验收。此结果不是实际微信首次连接、真实AI输出或发送回执验收。


### Connection settings sections — native preview verification

Rebuilt and relaunched the separate Preview app. Screenshots 22-24 show 微信连接, 使用偏好, and 本地资料. All three panes were opened through native accessibility controls; inactive pane content disappeared from the accessibility tree. Selecting 承诺追踪, switching to 微信连接, then returning to 本地资料 preserved the selected inner tab. No system permission, real connection, export, or real message action was executed. Source review confirms connection-root updates merge into the latest persisted configuration. Agent-reported scoped regression result: 22 tests passed; preview build independently succeeded.

Evidence: `22-connection-section.png`, `23-preferences-section.png`, `24-local-data-section.png`. This verifies section navigation and one local selection state; it does not prove preservation of an in-flight real connection task. Initial decryption-material provisioning and the installed app accessibility-trust mismatch remain open.


### Reply draft continuation — native preview

Opened 回复草稿 and clicked 继续回复 for the existing fictional 项目协作群 draft. Native detail composer contained the exact saved draft text. Screenshot `25-draft-continuation-detail.png` records the result. No send action occurred. This confirms opening/initial continuation; same-chat already-mounted replacement and cancellation still need native verification. The screenshot exposes a single-line 12pt editor and icon-only actions, making long replies difficult to review; multiline composition with explicit action labels is the next correction. Preview detail has no underlying message fixture and shows analysis unavailable, so this flow is not evidence of real group-context analysis.


### Multiline reply composer correction

`ConversationDetailView` now uses a 14pt multiline editor with a bounded height, accessibility label 回复内容, and visible 保存草稿 / 发送 buttons. Return no longer has an onSubmit send handler. Rebuilt Preview successfully (`/tmp/wechathud-multiline-preview.log`) and reopened the saved fictional draft. Screenshot `26-multiline-reply-composer.png` confirms editor and actions fit the floating detail panel. Clicking the first 发送 action displayed confirmation with the correct fictional recipient and complete draft text. During the subsequent cancel attempt CUA reported the app changed; a fresh snapshot showed 演示模式不会操作微信 and the full draft remained. Consequently cancellation itself is NOT counted as verified; no real WeChat send was performed, and the observed preview guard retained the text. Keyboard newline entry and already-mounted same-chat replacement remain to be checked.


### Draft replacement and Return key — native verification

Opened the existing fictional draft, added a second line through native editing, and observed 修改已自动保存. Clicking 继续回复 prompted replacement. Escape cancelled; opening 查看对话 showed the original composer text unchanged. Returning to the workbench and confirming 覆盖并继续 loaded the complete two-line draft. The confirm click returned an AX error, but a fresh snapshot established its successful outcome. Pressing Return in the editor inserted a new line and did not open send confirmation. Screenshot `27-multiline-draft-confirmed.png` shows the result. Both composer and saved draft were restored to their original fictional text, with automatic-save feedback confirmed. No real message or notification was sent. Detail was closed and reopened during this sequence, so the separate already-mounted same-chat continuation edge remains unproven.

### Current combined test result

`/tmp/wechathud-current-full-regression.log` records 759 XCTest tests with 4 skips and 0 failures, plus 70 Swift Testing tests across 12 suites passed. Skips: unavailable local classifier endpoint, two opt-in live companion cases, one opt-in live historical report case. The agent wrapper omitted process exit_code, so exit status is unrecorded; the passing summaries are the available evidence and were checked by root. No live AI opt-in flags were used. Subsequent make preview completed successfully with observed exit 0; log `/tmp/wechathud-current-preview-build.log`. This rebuilt artifact has not yet replaced the installed signed app.


### Onboarding remaining actions

Native screenshot28 exposed technical directory/key/sync checklist without a route. Replaced it with typed remaining actions grouped by user task; connection evidence remains three independent flags, summarized as 完成微信连接. AI setup/test and contact selection route to existing settings. Four focused readiness tests passed with exit0; agent recorded release build exit0 (46.13s). Root make preview exit0, restarted only Preview and traversed all four steps. Screenshot29 confirms readable action layout. Clicking 完成微信连接 returned to step1 with the connection primary action visible; no file authorization or real connection was performed. AI/contact final-page buttons were source-reviewed but not clicked in this existing-config fixture. Initial reading-material provisioning remains incomplete.


### Snooze expiry independent of scans

ChatMonitor's existing ten-second timer now checks expired in-memory snoozes before async work and scan gates. It rebuilds the unified inbox only when an expiry occurs and retains durable action rows and independent silence/dismissal state. New temporary-store tests exercise hidden-before-expiry, visible-at-exact-expiry without a scan, and preserving a later silence plus persisted timestamps. Root ran the full InboxActionPersistenceTests suite with observed exit0 (`/tmp/wechathud-snooze-recovery-tests.log`). This verifies unified inbox state; legacy unreadItems/suppressedItems restoration, app-not-running reminders, and native elapsed-time behavior are not covered. No real data or system notification was changed.


## 同一聊天保持打开的草稿接续验证

在现有 Preview 进程中，从“今天”打开项目协作群详情，再用 ⌘1 打开工作台（未关闭详情），修改虚构草稿并继续回复。取消替换后，查看对话仍是原输入；再次继续并确认替换后，详情显示完整两行草稿。截图 `30-same-chat-draft-continuation.png`。这补充了先前只有关闭/重开详情的证据。

同时发现继续编辑后点击详情“保存草稿”会新增条目，原条目不更新。已启动保存来源ID关联修复。验收产生的新增演示条目 id=3 已按精确时间、会话和内容条件移除；原条目 id=1 与详情输入已恢复原虚构文字。未发送消息。当前进程仍是此前已运行的 Preview，不将刚构建的磁盘包当作本次运行版本。

### 草稿原条目保存修复与原生回归

`ReplyDraftContinuation` 携带 savedDraftID，详情保存通过 chatUsername + id 原子更新，普通新回复保留新增行为。原条目删除与 SQLite 更新失败分别提示，不清空未保存文字；跨聊天重新建立状态。主代理重新执行 PanelStateTests / ProductWorkspaceTests，11 项通过，实际退出码 0（`/tmp/wechathud-draft-identity-final-tests.log`），包括删除、错误会话、trigger ABORT 保留原值。

`make preview` 退出码 0 后，结束旧 Preview PID 14094 并通过 CUA 启动新包。真实点击“继续回复”→修改为两行→“保存草稿”→返回草稿列表，列表保持 1 / 1；只读查询演示数据库确认仍为原条目 id=1，内容已更新，没有新增。截图 `31-save-continuation-updates-original.png`。测试文字已恢复，未发送消息、未改系统权限。当前签名 Candidate 包尚未包含这项新修复。

### 草稿修复 Candidate 更新

草稿接续身份修复已重新 release 构建并签名打入 `.build/WeChatHUD Candidate.app`，构建/打包实际退出码均为 0。主代理复核严格签名、bundle-check ready 和 203 个源文件哈希未变化。二进制 SHA-256 `94c0264571343e5cea3a19930a9114c7867fb39b01b0f5257dd480d250840fdb`；更新 `candidate-package-check.json`。未安装、公证或启动该候选 GUI；此前真实源读取证据绑定上一候选二进制，未将其冒充本包新测。

## 群 @ 跨入口来源一致性修复

审核发现列表摘要取最新非本人消息、群分析取最近50条/48小时，与精确来源简报不一致；简报还会先命中缓存再检查已消失的来源。

现已共享 `GroupContextSourceLoader`，按通知 chatUsername/messageID 定位源中心窗口；列表摘要及群分析缓存升级v3，查缓存前校验源。InboxContextBuilder接收同一窗口，不再内部取latest替代；群@分析不应用当前48小时过滤，并按ChatAnalyzer输入约定倒序，prompt明确触发消息。简报源缺失时不复用旧AI结果，专用说明只确认原通知、上下文未知、不建议直接承诺；Popover展示同时存在的errorMessage。

根代理检查最终代码并运行全量swift test：774 XCTest（4跳过）+70 Swift Testing，合计840通过、4跳过、0失败，实际退出码0；git diff --check退出码0。证据 `group-source-regression.json`。测试覆盖旧源、源丢失、缓存、超过48小时与消息顺序。相关Preview曾构建，但最终顺序/锚点修改后未重新启动GUI或调用真实AI；不把单元测试等同真实群聊输出验收，当前签名Candidate也尚未包含本轮改动。

## 群 @ 模型锚点实测与原生弹层待查

新增 opt-in `LiveCompanionAcceptanceTests.testSyntheticGroupAnalysisAnchorsMyActionToTriggeredMention`，使用虚构预算@我与后续其他成员会议室任务。实际配置 deepseek-v4-flash 返回预算行动项，没有把会议室任务归给我；退出码0。证据见 `synthetic-group-anchor.md`。仅临时业务库和虚构消息，不读取真实聊天、不发微信。

make preview完成后，主代理结束旧Preview PID26912并用CUA启动新包。先模拟通知并关闭工作台，浮窗显示“什么情况”；3秒时控件过期，暂改演示通知显示为15秒（UI显示保存成功）。再次模拟、关闭工作台并点击“什么情况”，AX未观察到简报，截图仍是通知横幅；随后浮窗超时消失。不能据此确认弹层成功，也尚不能区分按钮动作/SwiftUI弹层/工具窗口定位问题。当前原生缺源提示仍未验收。

已通过UI恢复演示通知展示时间为3秒，重新观察值及“提醒设置已保存”。没有修改正式应用配置或系统权限。下一步需诊断非激活浮窗内popover展示与实际窗口状态，不能把本次按钮点击当作成功打开。

## 弹层诊断被锁屏中断

本轮按diagnosing-bugs步骤检查：PanelState.popoverOpen已有暂停通知收起保护，不能仅凭超时认定根因。Luna只为Preview加按钮/showingPopover/onAppear/onDisappear临时事件记录并构建，准备确认点击是否触发及弹层是否创建。

结束旧Preview PID40234后，CUA启动返回“Mac is locked and automatic unlock could not unlock it”，因此没有取得点击事件、不能归因弹层故障。检查没有Preview进程和探针日志。已删除所有临时探针和专用import，rg确认消失，清理后make preview退出码0，git diff --check通过。当前需用户手动解锁Mac后继续原生复现；未更改系统锁屏或安全设置。

## 解锁后的弹层事件证据

Mac已解锁，根代理用CUA复测Preview模拟群通知。临时演示时长15秒，点击“什么情况”后记录：1788873944.137872 button-action；1788873944.144703 showingPopover=true；1788873944.164777 popover-appear。108秒后按Escape记录 showingPopover=false，随后popover-disappear。按钮动作与SwiftUI展示生命周期均发生，期间通知保持可见，不能再以原来的单窗口截图认定按钮未响应或通知计时器关闭了弹层。

CUA返回的AX与截图仍仅含通知横幅；截图底部可见小箭头，但未取得弹层正文。正文可读性、缺源提示和弹层操作仍未验收，独立窗口捕获限制与产品呈现问题尚未区分。没有据此修改产品行为。

通过UI恢复演示时长3秒并观察保存成功。Luna移除了全部临时日志代码及Foundation import，清理后make preview退出码0（/tmp/wechathud-popover-resume-clean-build.log）。未操作正式微信消息、正式配置或系统权限。

## 弹层渲染确认为工具捕获限制（2026-09-09）

在无探针Preview中把演示时长临时调回15秒，模拟群通知并点击“什么情况”后用swift CGWindowList枚举：主工作台窗口 X=-1655 且 onscreen=false（在左侧显示器），浮窗 460x150 layer101 onscreen，弹层 386x369 layer101 onscreen X=-1243 Y=133。此前 `screencapture -x` 全屏截到的是主显示器ChatGPT全屏，`Preview.getScreenshot` 只覆盖通知窗口，因此“AX/截图未见弹层”是捕获目标错误，不是弹层未渲染。

`screencapture -R-1300,100,500,450` 定点截图确认弹层完整可读：标题“什么情况”、项目协作群·林晓、“兜底”徽标、置信10%、警告“找不到这条 @ 消息，未使用其他消息冒充上下文”，以及发生了什么/为什么@你/当前状态/下一步四段和重新分析/复制结果/打开群聊按钮。此前未验收的原生缺源提示已通过：不编造上下文，明确要求先核对原文。

弹层窗口不在应用AX树内，CUA对其坐标点击返回 noWindowsAvailable，重新分析按钮未实际点按；这同时是产品可访问性待办（弹层应暴露AX窗口/元素）。Escape关闭后通过UI把时长还原为3秒，AX显示“Value: 3 秒”与“提醒设置已保存”。证据文件 /tmp/wechathud-popover-fullscreen.png、/tmp/wechathud-popover-region.png。未改动产品代码，未读取真实聊天。

## “什么情况”改为浮窗内原位展开（2026-09-09）

按目标要求由Luna子代理实现、根代理审核与验收：删除 SwiftUI .popover，改为按钮 toggle 原位卡片（GroupContextBriefingCard，通知横幅动作行下方与对话详情上下文区两处）。新增 PanelState.briefingExpanded（离开 .notification 自动双复位），AppDelegate 用 Combine sink 让通知面板高度随展开动画生长；popoverOpen 语义（暂停计时器、阻止鼠标移出收起）保持不变。按钮新增 accessibilityLabel。

验收（Preview模拟通知）：点击“展开上下文简报”后，卡片全部内容与重新分析/复制结果/打开群聊三个按钮出现在横幅窗口AX树（此前独立弹层窗口完全不在AX内）；CGWindowList只余一个 layer101 窗口 460x480（原150，+330），不再有独立弹层窗口；定点截图 /tmp/wechathud-inline-expanded.png 显示布局完整、层次清晰、无截断；实际点按“重新分析”无异常（演示缺源仍为兜底结果，符合预期）；收起后回到 273x32 紧凑胶囊、卡片从AX消失。swift test 777 XCTest（5跳过）+70 Swift Testing 全过、make preview 退出码0（Luna报告），演示时长经UI还原3秒并显示保存成功。

未操作正式微信数据；改动集中在简报交互与面板尺寸，未提交commit。

## 微信密钥准备改为 app 内一键引导（2026-09-09）

此前连接页在“允许读取”完成但缺少 ~/.wechat-cli/all_keys.json 时是死路（“这台 Mac 还不能直接连接”），普通用户无法完成首次使用，直接违反零猜测要求。本轮由Luna子代理实现、根代理审核：新增 WeChatKeyPreparationService（注入式 ProcessRunner，阶段机 idle/needsResignConsent/waitingForWeChatRelogin/extracting/needsResignAgain/succeeded/failed），把 wechat-cli 的 macOS 密钥提取链内建：codesign 检查微信 get-task-allow → 用户同意后一次性重签 → 用户重新登录微信 → 运行打包的 find_all_keys_macos.arm64 扫描进程内存 → Swift 端复刻 verify_enc_key 的 HMAC-SHA512 页校验 → 写入 ~/.wechat-hud/keys/all_keys.json（目录0700/文件0600）并更新 SyncConfig.keysFilePath。all_keys.json 采用 C 二进制与 WeChatReader.loadKeys 兼容的 {相对路径:{enc_key,salt}} 格式（偏离原规格的 salt->key 格式，规格有误）。Makefile/package-app.sh 打包复制二进制到 Resources/keytools 并 chmod +x。

验证：swift test 全量退出码0（783 用例、5 跳过），新增 WeChatKeyPreparationTests 6 例（无权限→同意门、task_for_pid→重试、成功解析+HMAC+可注入目录写入、校验失败、已有权限保持 idle、输出解析）独立过滤运行通过；make preview 退出码0，Preview.app Contents/Resources/keytools/find_all_keys_macos.arm64 存在、可执行、35720 字节与源一致；Preview 连接页冒烟显示演示文案与主按钮，死路文案消失。安全边界：任何 codesign/扫描前必须用户显式点击确认；服务从不自动退出微信；Preview 模式不执行真实流程。

边界：真实重签+真实提取只在真机连真微信时发生，属用户显式授权的系统操作，本轮未执行；该流程的真机端到端验收仍待做。未提交commit、未读取真实聊天。

## 设置页整改视觉复检全部通过（2026-09-09）

解锁后用CUA对锁屏期间完成的设置UI整改逐项截图复检：①使用偏好页——权限提示为左对齐缩进子行带小图标，“重新检查权限”按钮同行右侧，底部说明左对齐；②本地资料页——“导出报告”（头行右侧导出按钮+左对齐说明）与“记录回溯”（头行右侧分段控件，labelsHidden，空态居中）成功拆为两卡；③关注的对话详情——“编辑详情”绿色左置、“删除”红色右置，间距分离；④使用指南——标题/副标题与内容卡片左缘对齐；⑤工作台消息卡——主操作“理解上下文与回复”绿色实心（borderedProminent+accent），“稍后提醒”次级下拉，“已处理”ghost右置，层级清晰。此前对工作台按钮“无层级”的判断是截图分辨率不足的误判，予以更正。

至此前三处遗留视觉复检闭环，偏好设置五模块（连接与数据/使用偏好/本地资料/关注的对话/使用指南）当前视觉状态与 docs/design/ui-language.md 不变量一致。工作台/助理与“回复助理”仪表盘的深度走查仍待做；密钥准备真机端到端验收待用户授权（见 key-preparation-live-checklist.md）。

## 回复助理工作台空态教育升级（2026-09-09）

走查发现桌面端“回复助理”未开始空态只有一句话，安全边界不可见；紧凑浮窗版反而有规则说明。由Luna子代理实现：工作台空态新增宽560说明卡——三步行（自动整理需要回复的消息 / 按你的语气生成回复草稿 / 你确认后才发送；未开启“无人值守发送”时不会直接发微信）+ 私聊/群聊规则（ruleRow 字号适配工作台）+ “查看安全护栏”链接跳自动回复设置。每步合并为单个AX元素、数字圆标对读屏隐藏；紧凑版空态未动。

复检（Preview实机截图）：三步、规则、入口全部按规格呈现，左对齐无技术术语，卡片居中放置。swift test 全量退出码0（5 个 live 端点用例按设计跳过）、swift build 退出码0、make preview 退出码0。未 commit、未碰真实微信。

## 工作台五子模块走查与破坏性按钮统一（2026-09-09）

实机走查工作台五子模块（待办与跟进/我的承诺/回复草稿/聊天洞察/每日简报）：整体信息架构与视觉符合 ui-language.md，仅发现破坏性按钮违规两处。由Luna子代理修复：①回复草稿卡片“删除”加 role/foregroundStyle/tint(.red)（已有确认 alert）；②白名单扫描“忽略记录→删除”原无 role 无确认，补齐 destructive role、红色样式与“删除这条忽略记录？”二次确认 alert。

验收过程记录一个真因：全局 .tint(CompanionPalette.accent) 作用域内，.bordered 按钮标签被样式渲染为绿色，.foregroundStyle(.red) 单独不生效，需追加 .tint(.red)；ContactsSettingsView 的删除因不在该 tint 作用域内所以原写法就显示红色。实机定点截图确认草稿页“删除”已红、“查看对话”保持绿色。swift test 853 用例全过、make preview 退出码0。未 commit。

## 动画全面接入系统“减少动态效果”开关（2026-09-09）

盘点发现约50处动画调用时长合规，但仅6处尊重系统减少动态效果，违反 ui-language.md 不变量5。由Luna子代理实现 CompanionMotion 中央动画门（可注入 reduceMotionProvider 读 NSWorkspace.accessibilityDisplayShouldReduceMotion；ease/easeIn/easeOut/spring/springResponse/press/systemDefault 在减少动态时返回 nil；withMotion 保证 nil 时状态变化仍发生；View.companionAnimation 对应 .animation）。28处调用点、15个文件完成替换，7处手写 reduceMotion 三元统一删除；两个 repeatForever 循环（紧凑条呼吸1.2s、优先级脉冲1.4s）在减少动态时直接呈现最终态，无空转。全部时长与曲线数值未变。PixelBuddy 的 Timer 逐帧动画保留原 env 响应式实现（避免丢失系统设置变更时的刷新）。

验证：swift build 退出码0；swift test 787 用例（5跳过）+ make test 70 用例全过；目标文件已无直接 withAnimation/.animation 调用（rg 确认）；make preview 退出码0。实机冒烟：模拟通知→展开简报（spring 路径）→AX卡片完整→收起→关闭，均正常。未 commit。

## 分发打包管线本地验证（2026-09-09）

实跑 make package（退出码0）：release 构建 → WeChatHUD-DevCert 签名 → codesign valid 且满足 Designated Requirement（strict verify 通过）→ bundle-check ready（bundled_prompts/native_dependency 就绪，libzstd.1.dylib 校验通过）→ 归档 .build/distribution/WeChatHUD-1.1.4-macOS14-arm64.zip + SHA-256 清单，shasum -c 通过，keytools/find_all_keys_macos.arm64 已随包捆绑且可执行。spctl --assess 为 rejected（exit 3）属预期：未公证；按 docs/distribution.md 与 Makefile notarize 目标，公证是需要 Developer ID + NOTARY_PROFILE 的手动步骤（make notarize 只打印命令不上传）。“发布分享给普通用户”的本地管线完整，剩余用户侧动作仅为公证与上传。未 commit。

## AI 配置单槽化与交付 MVP 归档（2026-09-09）

响应用户更新目标（“AI配置不需要有本地服务和线上的了，就预设供应商和自定义供应商。完成目标，一个可以交付用户的MVP版本”）：
1. 模型与存储全面单槽化：AIConfig 收敛为单槽 provider（淘汰 cloudProvider/localProvider/activeMode/autoCloudFirst），解码自动无缝向下兼容老双槽数据及 legacy 结构，编码只写新槽。
2. AIService 彻底去除 fallback/auto 切换分流，全部走单一服务。
3. 默认工厂配置及当前用户配置已更新为预设 DeepSeek（deepseek-v4-flash），配置开箱即用。
4. 界面与文案重构：AISettingsView、OnboardingView（第2步）、CompanionGuideView 全面去除“本地/线上/自动”模式概念，统一呈现为“服务来源：预设供应商 | 自定义供应商”；OnboardingView 第1步在未连接时明确提示“完成微信连接后可继续”，消除用户猜测。
5. 测试全量回归：新增 AIConfigMigrationTests（10 个全覆盖测试用例）及相关重构，测试套件达到 857 个测试函数（787 XCTest + 70 Swift Testing），0 失败全部通过！
6. 发布交付：执行 `make package` 成功构建并打包最新版 `.build/distribution/WeChatHUD-1.1.4-macOS14-arm64.zip`（附 SHA-256 校验清单），内含签名完备、内嵌 zstd 动态库及一键密钥提取工具的完整 WeChatHUD.app。

## 新用户首次体验改造 + 崩溃修复（2026-09-09）

用户反馈“上线后新用户不知道这是干什么的”。走查确认三个断点：①首次启动只弹 400×420 小窗，标题“设置你的聊天伴侣”未说明产品价值；②引导第一步直接要求连接微信，价值未前置；③无回看入口。

改造（Luna 实现、根代理审核）：新增欢迎步骤（step 0），四步顺延为五步。欢迎页含大标题“你的微信聊天伴侣”、价值句“帮你读懂消息、记住承诺、组织回复——都在本机完成”、三条能力（群@我时/有人让你做事情时/需要回复时）与信任说明“只读取你明确选择的账号，不自动发送任何消息”。主按钮“开始设置”进入原流程；次按钮“先随便看看”打开工作台但不写 onboarded，下次启动仍显示引导。引导窗口 460×470、标题“欢迎使用 WeChatHUD”；step 0 顶部小标题改为“欢迎”消除与大标题重复。菜单栏新增“使用指南…”入口。

实机复检发现并修复一个真实崩溃：欢迎页点“先随便看看”触发 EXC_BAD_ACCESS/SIGSEGV，崩溃栈 objc_release → objc_autoreleasePoolPop → _AXXMIGPerformAction（AX 点击事件栈内同步 close 引导窗口，事件尾部 autorelease pool 弹出时访问已释放对象）。“开始设置”路径不崩。修复：AppDelegate 持有 onboardingWindow 引用（弃用按标题查找）、关闭改为 DispatchQueue.main.async 延后一帧、isReleasedWhenClosed=false、重复调用复用已有窗口；Luna 用一次性复现脚本对比旧逻辑（必崩）与新逻辑（200 次点击存活）后删除脚本。

复检证据：首次启动欢迎页正常渲染；点“先随便看看”后进程存活、无新增崩溃报告、onboarded 未写入、工作台正确打开（含“让聊天伴侣准备就绪”与“测试 AI 连接”引导卡）；点“开始设置”正常进入第 2 步且微信连接状态正确。swift test 797 用例 0 失败、make app 退出码 0。未 commit。
