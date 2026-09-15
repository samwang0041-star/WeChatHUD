# macOS HIG 走查与整改（2026-09-16）

依据：<https://developer.apple.com/design/human-interface-guidelines/designing-for-macos>

本文件是**按平台标准**做的体检表，不是新设计语言。`docs/design/ui-language.md`
管「青玉」这套自有视觉（材质、光、动效、模块色）——那部分继续有效。这里补的是
Apple 对 macOS App 的硬要求：菜单栏、系统文本样式、键盘可达性、系统辅助功能开关。

每条都写成「现状（可复核的数字）→ HIG 要求 → 整改 → 验收方式」，避免又出现
「感觉更原生了」这种无法验收的结论。

---

## 0. 先说清楚这个 App 是什么

`Resources/Info.plist` 里 `LSUIElement = true`：这是**配件型（accessory）App**，
常驻菜单栏、没有 Dock 图标、主窗口是吸顶浮岛。它只在两种情况激活：

1. 用户从菜单栏或快捷键打开工作台（`NSApp.activate(ignoringOtherApps: true)`）；
2. 浮岛进入文本输入（`panelState.islandTextInputActive`）。

一旦激活，App 的**主菜单栏就出现在屏幕顶部**。所以「配件型 App 不需要合规菜单栏」
是错的：用户看到的就是那条菜单。这条是本次走查的第一大项。

---

## 1. 菜单栏（现状：缺失大量系统标准项）

现状：`AppDelegate.configureMainMenu()` 手搓了 5 个菜单，共 14 项。

| 菜单 | 现有项 | HIG/系统标准要求 | 缺失 |
|---|---|---|---|
| App（关于本应用） | 打开工作台、设置…、检查更新…、退出 | 关于、设置…、服务、隐藏/隐藏其他/全部显示、退出 | 关于、服务、隐藏三项 |
| 编辑 | 撤销、剪切、复制、粘贴、全选 | +重做、删除、查找…、听写、表情与符号 | 重做（⇧⌘Z）、删除、查找、听写、表情与符号 |
| 显示 | — | 显示/隐藏边栏（⌃⌘S）、进入全屏幕（⌃⌘F） | 整个菜单 |
| 窗口 | 关闭窗口、最小化 | +缩放、全部置于顶层；且窗口列表要挂上 | 缩放、全部置于顶层 |
| 帮助 | 使用指南（⌘?） | 帮助（⌘?）+ 搜索 | 搜索 |

还有两处结构性问题：

- **关闭窗口 ⌘W 放在「窗口」菜单里**。macOS 把它放在「文件」菜单（无文件类
  App 也保留），「窗口」菜单只放最小化/缩放/置顶。用户肌肉记忆是 ⌘W 在文件菜单。
- **「关于/服务/隐藏」缺失的后果不是"少几个菜单项"**：`Services` 缺失意味着
  这个 App 无法参与「服务」生态（例如从别的 App 选中文字 → 服务 → 发给 WeChatHUD），
  而这正是本产品的天然用法。

`NSApp.mainMenu` 手动赋值后，AppKit 的自动补全逻辑不会再跑，所以这些必须显式加。

---

## 2. 文本与动态字体（现状：766 处硬编码字号绕过缩放）

现状：`Views/` 下 `.font(.system(size:))` 共 **766** 处；`companionFont(size:)`
（唯一会跟 `dynamicTypeSize` 缩放的入口）出现次数远低于此。字号直方图：

| 字号 | 出现次数 |
|---|---|
| 12 | 194 |
| 10 | 192 |
| 11 | 162 |
| 13 | 105 |
| 14 | 26 |
| 15 | 13 |
| 8 / 16 / 9 / 7 / 6 / 22 | 3 / 3 / 2 / 2 / 1 / 1 |

两个问题：

1. **7–9pt 仍然存在**（6 处）。HIG 的可读下限与 macOS 的 `mini` 控件档位都在
   11pt 附近，7pt 的字在任何显示器上都不是给人读的。`companionFont` 有 `max(10,…)`
   兜底，说明规则已经定了，只是有调用点没走这个入口。
2. **不走 `companionFont` 就等于不跟随系统文字大小**。macOS 的
   「系统设置 → 辅助功能 → 显示 → 文字大小」在这 766 处上完全无效，而在少数
   走了 `companionFont` 的地方有效——同一个页面里两套缩放行为，调大字号会散架。

HIG 的正面写法是**用语义文本样式**（`Font.body` / `.callout` / `.subheadline` /
`.caption` / `.caption2`），而不是数字。语义样式自带 Dynamic Type、正确的行高、
正确的字重与字距，并且跟随系统字体（含用户替换的系统字体）。

整改方向：把 `WorkspaceType` 从「数字」改成「语义样式映射」，保留当前视觉尺寸
（17/15/13/12/11/10.5 ≈ `.title3`/`.headline`/`.subheadline`/`.callout`/`.caption`/`.caption2`
在小号档位的实际点数），再把 766 处逐步收敛到 token。**收敛按文件推进并逐文件截图**，
不做一次性全局替换。

---

## 3. 系统辅助功能开关（现状：只接了两个中的两个，另两个完全没接）

现状统计：

| 系统设置项 | 代码里的响应 | 状态 |
|---|---|---|
| 减少动态效果 | `CompanionMotion.reduceMotionProvider` | ✅ 已接，且有闸门测试 |
| 降低透明度 | `CompanionMotion.reduceTransparencyProvider` | ✅ 已接 |
| **提高对比度** | 无 | ❌ 0 处引用 |
| **不用颜色区分** | 无 | ❌ 0 处引用 |
| 减弱闪烁 | 无（无闪烁内容） | n/a |

**提高对比度**缺失的实际后果：本 App 的层级靠 `CompanionPalette.border`
（`Color.primary.opacity(0.075)`）和 `CompanionElevation.edgeRamp` 的发丝线表达。
7.5% 的发丝线在提高对比度模式下应当加深、描边应当变粗——现在完全不变，
开这个开关的用户看到的是**比默认更糊**的界面（因为系统把其它 App 的边都加深了）。

**不用颜色区分**缺失的实际后果：`CompanionStatusDot` 等 45 处 `Circle()`／24 处
语义色前景是**只靠色相**传达状态（绿=正常、橙=待办、红=失败）。红绿色盲用户
（约 8% 男性）在这些点上读到的是三个一样的灰点。

---

## 4. 键盘可达性（现状：5 处 focusable，0 处 searchable）

| 项 | 数量 | 说明 |
|---|---|---|
| `@FocusState` / `.focusable(` | 5 | 几乎全靠在浮岛里抢焦点（`CompanionDialog` 的 `DialogKeyView`） |
| `.searchable(` | 0 | 工作台没有系统搜索框 |
| `.keyboardShortcut` | 15 | 集中在弹窗的 default/cancel |
| `.help(` | 32 | 相对 25k 行视图代码偏少 |
| `.contextMenu` | 4 | 右键菜单几乎没用起来 |
| `.onHover` | 8 | 悬停反馈同理 |

HIG 对 macOS 的要求里，键盘与指针是**一等输入方式**，不是触屏的补充：
Tab 要能走完整个界面（Full Keyboard Access）、Esc 要能退出当前层、Return 触发默认按钮、
右键要给出该对象能做的事、悬停要给出反馈与 tooltip。

---

## 5. 已经做对、不要在整改里弄坏的

这些是走查确认**符合 HIG 并且比系统默认更好**的地方，后续改动不得回退：

- **动效全部走 `CompanionMotion` 闸门**，`reduceMotion` 时归零，有源码扫描测试
  （`ChromeMotionHygieneTests`）禁止裸 `withAnimation(`。
- **`reduceTransparency` 全覆盖**：卡片阴影、洗层、材质在开启时换平坦填充。
- **对比度是算出来的**：`CompanionElevation.ambientLuminanceCeiling` 从
  「落在这层底上的字必须过 WCAG AA」反解，不是调出来的；实测 10.0–16.5:1。
- **弹窗留驻宿主窗口**：`CompanionDialog` 不新开窗口，`.isModal` trait、
  Esc 关闭、焦点进弹窗、背景 `accessibilityHidden`——这是 macOS sheet 的语义，
  只是画在窗口内，符合 v1 的「3 级不新开窗口」产品决策。
- **窗口可恢复且被夹回可见屏幕**（`SettingsWindow`），不会因为换显示器而跑到屏外。
- **`⌘,` 打开设置**、**`⌘?` 打开帮助**、**弹窗 default/cancel** 都已正确。
- 按压有 0.96 缩放 + 100–140ms 曲线，且 `reduceMotion` 时不缩放（u iii 有实测依据）。

---

## 6. 整改顺序（按「用户能感知到的程度 ÷ 风险」排）

| 轮次 | 项 | 状态 | 验收 |
|---|---|---|---|
| 1 | 菜单栏补齐到系统标准 | ✅ 本轮完成 | `MainMenuTests` 15 项 |
| 1 | 接入「提高对比度」 | ✅ 本轮完成 | `CompanionAccessibilityTests` 7 项 + 渲染 5 项 |
| 1 | 接入「不用颜色区分」 | ✅ 本轮完成 | 同上 |
| 1 | 大字号不再被钉死在默认档 | ✅ 本轮完成 | `CompanionTypeScale.range` |
| 2 | 语义文本样式 token + 收敛 766 处 | ⬜ 待做 | 逐文件截图 + 深浅色 |
| 3 | 键盘可达性（focus ring 已做，⌘F/Tab 顺序待做） | 🟡 部分 | AX 走查 |
| 4 | 右键菜单与 tooltip 补齐 | ⬜ 待做 | AX 走查 |

---

## 7. 本轮（第 1 轮）实际改了什么

### 7.1 菜单栏 — `Sources/WeChatHUD/App/MainMenu.swift`（新文件）

`configureMainMenu()` 从 30 行手搓菜单变成一次 `MainMenu.build(target:)`，
并把 `servicesMenu` / `windowsMenu` / `helpMenu` 分别注册（这是三个独立的
AppKit 握手，只设 `mainMenu` 不会发生）。

补上的标准项：关于、服务、隐藏/隐藏其他(⌥⌘H)/全部显示、文件→关闭窗口(⌘W)、
编辑→重做(⇧⌘Z)/粘贴并匹配样式/删除/查找(⌘F,⌘G,⇧⌘G,带 `NSTextFinder.Action` tag)、
显示→打开工作台(⌘1)/刷新(⌘R)/显示隐藏边栏(⌃⌘S)/进入全屏幕(⌃⌘F)、
窗口→缩放/全部置于顶层。

⌃⌘S 的实现方式值得记一笔：SwiftUI 的 `NavigationSplitView` **不认领**
`toggleSidebar:`，所以走响应链会得到一个按下去没反应的菜单项。
菜单项改为发 `Notification.Name.hudToggleSidebar`，`SettingsView` 持有
`columnVisibility` binding 来真正切换。

### 7.2 提高对比度 — `Sources/WeChatHUD/Views/CompanionAccessibility.swift`（新文件）

新增 `CompanionAccessibility`，形状与 `CompanionMotion` 对齐（可注入 provider、
两个开关、一个系统通知桥）。

- `borderOpacityScale`：7.5% 的发丝线 → 18%。2.4 这个倍率的依据是把 7.5%
  抬到 `NSColor.separatorColor` 在提高对比度变体下的同一档（约 0.18）。
- `cardEdgeWidth`：卡片描边 1 → 1.5。上限 1.5 是因为再粗就从「卡片自己的边」
  变成「画在卡片外面的框」。
- `contrastAdjusted(_:)` 带 0.32 封顶：装饰性洗层（环境光、hover 层）不允许
  被放大成一条边。

**踩到的坑（值得记录）**：这些 token 是 **static**。SwiftUI 只会因为「body 里
读到的东西变了」而重绘，而 body 里读一个 static 不建立任何依赖——所以卡片会
心安理得地保持旧颜色。修法是加一个 `CompanionAccessibility.generation`，
由通知 bump，经 `.companionDisplayGeneration(_:)` 放进环境，凡是外观由这些
static 算出来的视图都读一下它。同样的缺口在 Reduce Transparency 上也存在，
之前预览按钮「看起来能用」只是因为顺带重设了 demo chrome 的 `.id`。

原始 border 调用点（8 处）改走 `CompanionHairline` / `companionHairline()`，
让它们也进这条依赖链。

### 7.3 不用颜色区分

`CompanionStatusDot` 新增 `Level`（`.ok` / `.working` / `.attention`）与
`Level.Silhouette`（圆盘 / 圆环 / 菱形）。开关关闭时三个 level 渲染完全相同
（有渲染测试断言 0 像素差异），打开时才分化成三种轮廓。

### 7.4 大字号

`SettingsView` 与 `HUDRootView` 原本写死 `.dynamicTypeSize(.large)` ——
**这是个硬钉死**：用户在系统设置里调大文字大小，这个 App 毫无反应，
而它自己的预览里却有一个「模拟大字号」按钮证明布局吃得下。
改成 `CompanionTypeScale.range = .large ... .accessibility2`，
下限仍是 `.large`（浮岛 36pt 固定高 chrome 的实测尺寸在默认档取得），
上限 `.accessibility2`（已走查过的最大档）。

### 7.5 键盘焦点环

侧栏 18 行是手搓的（需要渐变填充 + 计数胶囊），不是 `List`，
所以 Tab 会穿过 18 个**不可见**的停靠点。新增 `companionFocusRing(_:radius:)`
用 `NSColor.keyboardFocusIndicatorColor`（系统焦点环色，不是品牌玉色，
这样和 Finder 并排看是一致的），由 `SettingsSidebarSections` 的 `@FocusState`
驱动。

### 7.6 验证方式

- **单元**：`MainMenuTests` 15 项（菜单结构、顺序、快捷键无重复、分隔符不连续）、
  `CompanionAccessibilityTests` 7 项（token 数值与开关关闭时的恒等）。
- **安装**：`MainMenuInstallationTests` 2 项。它跟另外两道闸门的分工要说清楚——
  `MainMenuTests` 证明**树是对的**，源码扫描证明**调用点存在**，
  这两个都可以在「菜单根本没装到 NSApp 上」时全绿。
  它们真的全绿过一次：`configureMainMenu()` 曾经被注释掉，
  两道既有闸门都过了，只有真跑一遍启动钩子才看得出来。
  这条测试调用 `applicationWillFinishLaunching`，然后断言
  `NSApp.mainMenu` 的六个标题、以及 `servicesMenu`/`windowsMenu`/`helpMenu`
  **是同一批实例**（注册一个不同的 NSMenu 会产生一个永远不填充的「服务」
  和一个没有窗口列表的「窗口」，截图上看不出来）。
- **渲染**：`CompanionAccessibilityRenderTests` 5 项，用 `ImageRenderer`
  真的把视图画成位图再比像素。这是唯一能证明「token 到了屏幕上」的手段——
  纯 token 测试在依赖链断掉时依然全绿。
- **像素实测**：在真实进程里抓同一页面的两种状态，扫描卡片左边缘所在的那条
  扫描线：常态是 2px @ L52，提高对比度是 3px @ L78。
- **可复现启动**：`--preview-contrast` / `--preview-no-color` / `--preview-large-type`
  与既有 `--preview-tab` 同一机制，让「在这个开关下截一张图」变成一条命令，
  而不是去点按钮（点按钮会移动指针且无法重放）。

### 7.7 本轮**没有**做的事（下一轮）

- 766 处硬编码字号的收敛。这是最大的一块，但不是可以一次性全局替换的：
  `WorkspaceType` 现在还是数字 token，要改成语义文本样式映射并逐文件截图回归。
- ⌘F 在工作台里已存在（`AssistantTodayView` 的搜索框），但没有走
  `NSTextFinder` 链路，因此菜单里的「查找」只在有文本查找器的页面上点亮——
  这是正确行为，但「⌘F 跳到页面搜索框」还没做。
- 右键菜单只有 4 处、`.help()` 只有 32 处，相对 25k 行视图代码偏少。

---

## 8. 参考

- Apple HIG：Designing for macOS — <https://developer.apple.com/design/human-interface-guidelines/designing-for-macos>
- Apple HIG：Menus — <https://developer.apple.com/design/human-interface-guidelines/menus>
- Apple HIG：Accessibility — <https://developer.apple.com/design/human-interface-guidelines/accessibility>
- Apple HIG：Typography — <https://developer.apple.com/design/human-interface-guidelines/typography>
- 本项目视觉语言：`docs/design/ui-language.md`
