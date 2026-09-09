# 原生 macOS / AI 工作台开源 UI 参考

调研日期：2026-09-08（Asia/Shanghai）

这是一份只读调研。项目均通过 GitHub 公开仓库的 README、源码页面和仓库内许可证核验；没有克隆、运行或复制第三方程序、代码、图标和品牌素材。GitHub stars 是本次访问时的快照，之后会变化。下文的“建议”是基于公开交互实现的产品推导，不代表 WeChatHUD 应直接移植任何实现。

## 快速结论

适合 WeChatHUD 的组合是：用 **boring.notch** 参考吸顶浮窗的“闭合摘要 → 展开工作区”节奏，用 **Maccy** 参考键盘优先、搜索即筛选和多种选择动作，用 **Ice** 参考显式分组、隐藏内容的可发现性和搜索面板，用 **Rectangle** 参考原生状态栏入口、简洁设置表单、快捷键配置和可恢复的状态反馈。

四个项目的许可证不同：boring.notch 和 Ice 是 GPL-3.0，Maccy 和 Rectangle 是 MIT。本文只借鉴交互思想，不复制代码、品牌、图标、文案或视觉素材；若将来引入任何第三方代码，必须单独做许可证与归属审查。

## 项目核验

### 1. boring.notch：把吸顶区域做成“短暂摘要 + 可展开工作区”

- [仓库 / README](https://github.com/TheBoredTeam/boring.notch)：GitHub 页面显示约 **10.6k stars**（本次快照），README 描述了 notch 音乐控制、visualizer、calendar、file shelf 和 HUD replacement，并明确写出“hover over the notch to see it expand”。
- [许可证](https://github.com/TheBoredTeam/boring.notch/blob/main/LICENSE)：GPL-3.0。
- [BoringViewCoordinator.swift](https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/BoringViewCoordinator.swift)：源码将 `currentView`、`sneakPeek`、`expandingView` 等状态集中在 `@MainActor` coordinator 中，并为短暂提示安排取消/延迟任务；状态变化通过 SwiftUI animation 更新。
- [ContentView.swift：状态布局与 hover/gesture](https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/ContentView.swift#L1707-L1755)、[ContentView.swift：hover 延迟与弹簧动画](https://github.com/TheBoredTeam/boring.notch/blob/main/boringNotch/ContentView.swift#L2422-L2502)：源码在 closed/open 状态间使用 spring 动画，hover 会取消旧任务、等待最小 hover 时长后再打开，离开时又有短暂延迟，避免鼠标经过就立即关闭；同时支持点击和上下拖拽手势。

**可借鉴到 WeChatHUD 的具体行为**

1. **摘要层只承担提醒，展开层才承担操作。** CompactInboxBar 只显示未读数、最高优先级联系人和当前状态；点击或稳定 hover 后再展开 Inbox/Detail。把“看见”与“处理”分开，避免 36px 浮窗塞入过多按钮。
2. **展开和收起都要有意图门槛。** 采用短 hover dwell（例如 100–180ms）和收起 grace period；用户从浮窗移动到 ActionPanel 时不应因跨过边界立即收起。已有 PanelState 三态可将该门槛作为状态机事件，而不是散落在视图手势里。
3. **短暂状态要有生命周期。** AI 正在分析、同步完成、发送成功、需要人工确认等提示应带取消/超时策略；新的提示替换旧提示时，不能留下一个永不消失的 banner。
4. **媒体化动效只服务状态转移。** 可参考 closed/open 之间的 spring 和 shared element 过渡，但不复制其角色形象或视觉素材；Inbox 的联系人头像、优先级色标和操作按钮应保持产品自己的语义。

## 2. Maccy：高密度、键盘优先的原生弹出工作台

- [仓库 / README](https://github.com/p0deje/Maccy)：GitHub 页面显示约 **21.5k stars**（本次快照）。README 将产品定位为轻量、快速、键盘优先、原生 UI，并把弹出、搜索、选择、粘贴、删除、固定和 Preferences 的路径写成完整操作链。
- [许可证](https://github.com/p0deje/Maccy/blob/master/LICENSE)：MIT。
- [PopupPosition.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/PopupPosition.swift#L353-L477)：源码提供 cursor、statusItem、window、center、lastPosition 多种定位策略，并将弹窗约束在当前屏幕的 visible frame 内；status item 定位还会把按钮坐标转换到 screen 坐标。
- [Selection.swift](https://github.com/p0deje/Maccy/blob/master/Maccy/Selection.swift#L268-L321)：把 selection 作为独立的小型状态模型，提供 empty/count/first、按索引遍历、增删操作，便于键盘选择和视图解耦。
- [README：Usage](https://github.com/p0deje/Maccy#usage)：README 明确列出 Enter、Option+Enter、Option+Shift+Enter、Option+Delete、Option+P 等不同动作；同一条目可以“复制”“粘贴”“无格式粘贴”“删除”“固定”。

**可借鉴到 WeChatHUD 的具体行为**

1. **搜索框一出现就能输入。** 打开 HUD 的 extended/detail 后，焦点直接落到会话/事项搜索；输入即筛选，不再要求先点某个 tab。空搜索显示按紧急度分组的队列，输入联系人、关键词或 `P0`/`待确认` 可叠加筛选。
2. **同一行保留主动作，修饰键提供次动作。** Enter 打开或执行首要动作，Option+Enter 可执行“完成并收起”或“打开草稿确认页”，Option+Delete 可取消/清理草稿；这些动作必须在 footer 或 tooltip 中持续可发现，不能只靠隐藏快捷键。
3. **把选择状态做成独立模型。** InboxRowView、CommitmentTabView 和 PendingAsk 列表应共享 selected item / focus index 语义，支持上下键移动、Enter 打开、Esc 返回、Space 展开操作区；列表刷新时保留稳定 ID，避免焦点跳到另一条消息。
4. **弹窗位置由入口决定并做屏幕边界约束。** 从菜单栏点击时贴近 status item，从全局快捷键打开时使用上次位置或当前屏幕中心；无论入口如何，detail panel 必须限制在 NSScreen.visibleFrame 内，并沿用当前 displayScreen 选择。
5. **密度来自动作层级，而不是缩小字体。** 行内只保留联系人、时间、状态和一个主按钮；次动作放入 hover ActionPanel 或 keyboard command menu。这样可以在 500px detail 工作区显示足够信息，同时维持 macOS 原生可读性。

## 3. Ice：用显式分组控制“现在看什么”和“暂时隐藏什么”

- [仓库 / README](https://github.com/jordanbaird/Ice)：GitHub 页面显示约 **29.5k stars**（本次快照）。README 将功能拆成 menu bar item management、appearance、hotkeys 和 other，并列出 always-hidden section、hover/empty-area/scroll reveal、drag-and-drop arrange、search、profiles 和 groups。
- [许可证](https://github.com/jordanbaird/Ice/blob/main/LICENSE)：GPL-3.0。
- [MenuBarManager.swift](https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/MenuBarManager.swift#L1047-L1154)：源码将 visible、hidden、alwaysHidden 三个 section 初始化成明确的数据对象，并把 Ice Bar panel 与 search panel 作为独立 panel 管理；这说明“显式分组 + 单独搜索入口”是结构，而不是单纯的颜色区分。
- [MenuBarManager.swift：系统状态与 rehide 监听](https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/MenuBarManager.swift#L1158-L1250)：源码监听系统 menu bar 隐藏状态和 frontmost app，按 focused app 策略延迟重新隐藏，避免用户刚展开内容就被立即收走。

**可借鉴到 WeChatHUD 的具体行为**

1. **把 Inbox 分成可解释的层级。** 建议使用 `现在处理`、`等待对方`、`已归档` 三个稳定分组；每组显示数量和最近更新时间。P0、未读和即将过期事项进入“现在处理”，只有明确由对方执行的事项进入“等待对方”；低风险信息作为普通更新或信息备忘保留，历史记录默认收起。
2. **隐藏必须可发现、可恢复。** 收起低优先级组时保留一行“还有 N 条等待处理”，点击、滚动或快捷键可展开；不能把被隐藏的消息变成用户无法证明存在的黑箱。Compact 状态仅显示高优先级摘要时，同样提供 badge 和 `⌘K` 搜索入口。
3. **重排和筛选要保留结果反馈。** 若支持拖动调整分组顺序或收藏联系人，应在落点处给出可见反馈，并把结果保存到 HUDStore；刷新消息后不能恢复默认顺序。搜索结果应显示当前所在分组，清除搜索后回到原来的焦点。
4. **前台应用切换不能破坏操作。** 如果用户从 WeChatHUD 切换到微信执行动作，返回时应保留当前会话、选中行和 pending 状态；只在明确的收起事件或完成确认后关闭 ActionPanel。

## 4. Rectangle：简洁原生设置、状态栏入口和可恢复的操作反馈

- [仓库 / README](https://github.com/rxhanson/Rectangle)：GitHub 页面显示约 **29.8k stars**（本次快照）。README 把产品描述为 macOS 窗口管理器，核心入口是键盘快捷键和边缘 snap areas；同时说明设置界面保持 intentionally simple，并将额外动作收纳到 General 页底部的 ellipsis。
- [许可证](https://github.com/rxhanson/Rectangle/blob/main/LICENSE)：MIT。
- [RectangleStatusItem.swift](https://github.com/rxhanson/Rectangle/blob/main/Rectangle/RectangleStatusItem.swift#L312-L395)：源码用 `NSStatusItem` 绑定 `NSMenu`，通过 `refreshVisibility` 管理显示/删除，并监听 status item 的 `isVisible` 变化，在图标被系统移除时写入持久状态；`openMenu` 在需要时先恢复 item 再触发点击。
- [README：snap areas](https://github.com/rxhanson/Rectangle#how-to-use-it)：README 用边缘、顶部、四角、三等分等具体触发区域解释行为，并说明释放鼠标前会显示目标 footprint，让用户提前知道即将发生什么。
- [README：Import & export JSON config](https://github.com/rxhanson/Rectangle#import--export-json-config)：README 记录设置页的 JSON 导入/导出、启动时配置读取和时间戳改名策略，形成“可迁移且不会反复误读”的配置闭环。

**可借鉴到 WeChatHUD 的具体行为**

1. **状态栏入口必须能恢复。** WeChatHUD 的 menu bar item 被系统隐藏、屏幕变化或用户关闭后，设置页和主菜单仍应提供“显示助手/恢复状态栏图标”的路径；图标不可见时不能让用户失去唯一入口。
2. **设置按“常用动作 / 进阶配置”分层。** 系统、同步、AI、自动驾驶和数据管理用清晰 section 分组；少量高频开关直接展示，密集的高级规则放进“更多设置”或 sheet。每个需要重启、授权或切换账号的选项必须在行内说明影响。
3. **先给出操作预览，再提交。** 对发送、批量完成和切换账号等不可逆或高影响动作，先显示目标范围、预计变化和权限状态；用户确认后才执行。可参考 snap footprint 的思想：在 commit 前让用户看到动作落点。
4. **配置要可导出、可恢复、可解释。** 对快捷键、通知偏好、分组顺序和 AI/Autopilot 规则提供 JSON 导出或诊断摘要；导入时做 schema/version 校验，并在失败时保留旧配置和给出可操作错误。

## 落到 WeChatHUD 的优先级建议

### P0：先统一浮窗交互契约

1. Compact → extended 使用稳定 hover dwell、点击和明确的 Esc/收起路径；ActionPanel 出现后，鼠标从行移到按钮不能触发误收起。
2. 所有弹出窗口根据入口选择 anchor，并限制在目标屏幕 visible frame；屏幕变化时重新计算位置但保留当前状态。
3. 全局快捷键打开后焦点落到搜索或当前选中行；上下键、Enter、Esc、Space 的行为在 Inbox、Commitment 和 PendingAsk 中保持一致。

### P1：把密度和状态变成可解释的结构

1. Inbox 使用三个固定分组：现在处理、等待对方、已归档；每个分组提供数量、更新时间和展开/收起状态。
2. 紧凑模式只展示需要用户决定的摘要，并始终保留 badge、搜索或菜单入口来找回隐藏项。
3. 同一行只显示一个主动作；次动作通过 hover ActionPanel、快捷键和详情页出现，并给出成功、失败、待确认和需重启等明确 receipt。

### P2：补齐设置和恢复能力

1. 设置页采用 macOS section + row 结构，常用项直接操作，高级项放入 sheet；每个持久化字段显示立即生效/重启生效/需授权的状态。
2. 为快捷键、通知、分组顺序和 Autopilot 规则增加导出、导入前校验和失败回滚；导出的内容不包含微信原文、密钥或 AI token。
3. 对状态栏图标、外接屏幕、权限和微信连接分别提供“当前状态、原因、下一步”三段式反馈，确保 UI 状态与真实可执行状态一致。

## 许可与引用边界

- 本文只使用公开仓库页面作为事实来源，不包含第三方源码复制、二进制、图标、品牌素材或截图。
- GPL-3.0 项目（boring.notch、Ice）的交互观察不等于可以复制其实现；不要将其源码片段直接放入 WeChatHUD。
- MIT 项目（Maccy、Rectangle）允许更宽的再利用，但若未来实际复制代码，仍需保留许可证与版权声明并单独审查依赖；当前建议继续只实现同类交互思想。
- 所有截图与视觉验收由主负责人另行完成；本文没有声称看过或验证第三方应用的实际运行截图。
