# 2026-09-12 全状态精修与性能收口（执行记录）

用户诉求：逐一体验 HUD 每个状态的文案/界面/布局/设计，精修视觉-动画-布局，优化算法，并提升运行效率、降低负载；质检必须用 computer use 且不影响真实鼠标。

## 一、质检方式

- 通道：`make preview` 隔离预览进程（`com.wechathud.product-preview`），只读虚构数据，不读微信、不发送消息。
- 交互：`mcp__cua_repl__js` 的**元素级**点击（`app.click(index)`）。验收过程中发现坐标/元素点击会带动真实光标，于是改为新增预览专用启动旗标 `--preview-hold-island` / `--preview-disconnected` / `--preview-tab=<page>`，实现**零鼠标移动**的状态与页面截图。
- 截图：进程内 `PreviewRuntime.captureSurfaces` 位图 + `CGWindowListCopyWindowInfo` 取真实窗口几何。
- 产物：`/tmp/hud-audit/`（各状态与页面截图、CUA 质检报告 `qa-cua.md`、全局 chrome 事实 `notes-g0-chrome.md`）。

## 二、实机发现的缺陷与修复

| 缺陷 | 证据 | 修复 |
| --- | --- | --- |
| 断连态文案重复成「上次同步 270分钟前同步」 | `03-disconnected-island.png` | `InboxView.islandStatusBanner` 不再套用带后缀的 `syncLabel`，改为裸相对时间；新增 `SyncStampWordingTests`（含源码级守卫） |
| 首个状态（首次浮窗）以外，行展开后鼠标移开不收起 | 实机复现 | 根因是 `captureSurfaces` 把 `popoverOpen` 置真后从不复位；改为捕获前后成对处理；`PanelState.menuTrackingOpen` 增加 60s 兜底，防止 AppKit 漏发 didEndTracking 时永久卡开 |
| 草稿页页头与列表叠字 | `50-drafts-repro.png`、`51-drafts-crop.png` | 详情列改为内部 `ScrollView`，分割区 `frame(maxHeight: .infinity) + clipped()` |
| 草稿页按钮行溢出，主操作「继续回复」被裁 | 实机复现 | 抽出共享 `FlowRow` 布局（换行而非溢出）；两栏最小宽度 260+360 改为 200+280 |
| 草稿页把群聊标为「私聊」 | 实机复现 | 新增 `isGroupChat`：优先信 `inboxItems.isGroup`／白名单 `isGroup`，用户名形状仅作兜底 |
| 关注谁页 inspector 列被裁（账号信息/整理范围等标签不可见） | `fx-contacts` 截图 | 窗口最小宽度 820→900（两栏页在 820 下放不下），并收窄该页两栏最小值 |
| 今日小结把会话名回退成裸账号 `preview-colleague` | `page-dailyReport.png` | `resolveDisplayName` 新增 `unnamedContactPlaceholder`，不再把 raw id 当显示名 |
| 预览工具条 15 个按钮被压成竖排单字 | `01-first-launch-workspace.png` | `SettingsPreviewChrome` 改 `LazyVGrid` 自适应栅格 |
| 引导声称 3 步但只有 2 页，第 3 个点永远不亮 | `61/62-onboarding-*.png` | `FirstLaunchGuide.pageTitles` 派生自 `contentPageCount`，指示器与无障碍文案同源 |
| 引导步进条无障碍文案重复 6 遍 | AX 树 | 容器 `.accessibilityElement(children: .ignore)` |
| 侧栏同时用 trait 与自定义值表达「已选中」，读屏播报两个选中项 | AX 树 | 改为项目既有约定 `.accessibilityTags(.isSelected)` |
| 预览通知时长泄漏：900 秒被写进预览库 | 预览库 `settings.notification` | 保持时长改为传参 `holdSeconds`，不再改写持久化设置；新增 `PreviewHarnessHygieneTests` |

其余分栏页（聊天回顾 / 待办 / 待确认回复）一并收窄最小宽度，消除同类裁剪隐患。

## 三、性能与算法

- 心跳：等值短路 + `tolerance`，无待发队列时 10s→30s（有队列即回 10s）。
- 主线程：摘要取数移出 MainActor；展开态预取限制为可见前 3 条（原为每行 2 次 AI 调用）。
- SQL：语句缓存、去掉让索引失效的 `CAST` 谓词、草稿计数改 `COUNT(*)`、pending 查询加 LIMIT 与脏标记。
- 扫描：复用 session 快照、归档节流 1 小时、ephemeral purge 保留 mtime、key 查找建索引、manifest 去抖写。
- 渲染：PixelBuddy 帧表记忆化 + Canvas 单次绘制 + 生命周期停表（离线像素对比 10 个 mood 逐字节一致）。
- 算法：4 处 `Dictionary(uniqueKeysWithValues:)` 改为保留先到者（原先 key 重复会直接 trap 崩溃）；排序补末级 tiebreaker；回复债务锚点改为「最近一条未被实质回应的入站」（修 ack 吞掉正事、群 @ 被后文闲聊覆盖两类漏判）；群 @ 溯源改快路径。

## 四、验证

- `swift build`：通过，无 error。
- `swift test`：**1368 用例、0 失败、10 个显式 live 门禁跳过**（与改动前基线一致，无新增跳过）。
- 实机矩阵：深/浅色、初次浮窗、同步中、断连、空收件箱、任务预览、通知横幅、行展开、引导两页、大字号、减少动态、减少透明、扩展屏、草稿/待办/承诺/回顾/日报/待确认回复/关注谁等页面均截图复核。
- 遗留：非预览构建下草稿页是否仍重叠、`我答应的事` 选中态读屏语义、真实数据下的裸账号名，需要真实微信环境复验（预览数据无法覆盖）。

## 五、变更规模

- 42 个文件改动（+2872 / −865），35 个新增文件（含 24 个新测试文件与 2 个新源文件）。
- 性能与算法审计的完整清单保存在 `/tmp/hud-audit/`（CUA 报告 + 全局 chrome 事实 + 各状态截图）。
- 审计中「确认为有意设计、不要动」的清单（如扫描 seed 语义、事务水位、回复宽限期、P0/P1/P2 阈值）已逐条保留，未做改动。
