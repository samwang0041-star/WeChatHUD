# macOS HIG 前端精修验收（2026-09-15）

目标：按 Apple《Designing for macOS》的标准，优化精修整个前端视觉交互。
参考：<https://developer.apple.com/design/human-interface-guidelines/designing-for-macos>
（该域名在本机网络下不可直连，HIG 条款通过公开镜像与既有规范核对；条款编号沿用
`docs/qa/2026-09-15-frontend-quality-pass.md` 的 8 条清单。）

本文记录**这一次实测到的证据**，不是计划。所有"实测"数字都来自两个可复现的入口：

- `--preview-hig-audit=<秒>`：进程内读自己的 `AXUIElement` 树（VoiceOver 读的同一棵树），
  记录每个可交互控件的 role / 名称 / 帮助 / **屏幕坐标与尺寸**。
- `--preview-capture=<秒>`：同一进程内按窗口写 PNG，无需鼠标、无需跨进程通知。

两者都是本轮新增的，原因见「测量本身修掉的两个坑」。

---

## 一、抓到的阻断级缺陷：菜单栏是空的

**`configureMainMenu()` 被写了、被注释、被单元测试覆盖 —— 从来没有被调用过。**

`MainMenu.swift`（252 行）把 macOS 标准菜单逐项建好，`MainMenuTests`（283 行、15 条断言）
逐项验过。但 `AppDelegate` 里没有任何一个 launch hook 调用它。后果：

- 菜单栏只显示应用名，`文件 / 编辑 / 显示 / 窗口 / 帮助` 六项**在屏幕上不存在**；
- 关于、服务、重做（⇧⌘Z）、显示/隐藏边栏（⌃⌘S）、进入全屏幕（⌃⌘F）**全部不可达**；
- 没有"服务"菜单意味着这个应用**无法接收任何其他应用发来的文本**；
- 而 `swift test` 全绿。

实测证据（同一份源码，只差那一行调用）：

| 状态 | 进程内读到的菜单栏 |
|---|---|
| 有调用 | `mainMenu=WeChatHUD\|文件\|编辑\|显示\|窗口\|帮助` |
| 无调用（模拟出厂缺陷） | `mainMenu=`（空） |

**修法**：在 `applicationWillFinishLaunching` 里调用 —— 那是 Apple 文档指定建主菜单的地方，
在任何窗口出现之前执行，所以第一次激活就已经带着菜单。

**补的门**：`MainMenuWiringTests`。它扫源码找那个调用，因为缺陷是"调用不存在"，
测被调用者本身永远测不出来。

### 这个门自己被验证了三次才成立

值得记下来，因为它三次都**对着真缺陷通过了**：

1. 第一版用 `contains("configureMainMenu()")` —— 把调用注释掉，字符串还在，门照样绿。
2. 第二版加了"跳过注释行"，但函数体的结束位置用字面量 `"\n    func "` 找，
   漏掉 `private func` / `@objc func`，于是"函数体"延伸几百行，
   把 `configureMainMenu` 的**定义本身**当成了调用 —— 又绿。
3. 第三版用正则找下一个函数声明、要求被检查的行**整行等于**该语句，才真正失败。

**教训**：源码扫描门必须拿真缺陷跑一遍，"写得像门"和"能失败"是两件事。

### 同一条链路上的第二个静默缺陷：快捷键监视器吞掉了菜单键

`AppDelegate` 用 `NSEvent.addLocalMonitorForEvents` 装了全局按键监视器。
它在 AppKit 把按键匹配到菜单**之前**拿到事件，返回 `true` 就吞掉。
而它的 `handleKeyDown` 自己认领了 **⌘1 和 ⌘,** —— 正是菜单栏里
`显示 > 打开 WeChatHUD` 和 `设置…` 标注的那两个快捷键。

后果：按 ⌘1 执行的是"打开今天"而不是菜单上写的动作，菜单项**永远点不到**。

`MainMenuTests` 测不出来：它单独构造菜单，而"藏在另一个文件里的处理器"正是
"单独"这个词排除掉的东西。

**修法**：监视器只认领 cancel（⎋ 与 ⌘.）。规则抽成纯函数 `KeyboardShortcutPolicy`，
按目标窗口（浮岛 / 工作台 / 其他）+ 是否有 sheet 决定动作：

- 浮岛 ⎋ → 收回刘海；工作台 ⎋ → 关窗；其他窗口 → 不管（留给焦点控件）。
- 带 ⌘/⌥/⌃ 的 ⎋ 不是我们的（⌘⎋ 是系统强制退出）。
- **有 sheet 时一律不接管** —— 否则会把"确认发送"从用户手里关掉，丢掉他正在确认的内容。
- ⌘. 也是一条取消键，之前只实现了⎋。

**补的门**：`KeyboardShortcutPolicyTests`（9 条），其中一条扫源码确认
`handleKeyDown` 不再匹配字符、不再 gate 在 ⌘ 上。

`设置…` 另外**不再强制跳页**：它以前会顺带跳到「微信连接」，
所以从「待办」按 ⌘, 会丢掉当前页并落到一个带副作用的连接页。
⌘? 是 `openGuide`，菜单项自己就叫「怎么用」，那种"目的地"项选页是对的。

---

## 二、实测到的具体缺陷与修法

用 `--preview-hig-audit` 跑了 23 次启动（17 个页面 + 浮岛 3 态 + 浅色 3 页），
共 1189 个控件样本。

### 2.1 无名控件（VoiceOver 读不出来）

**修复前**：12 个页面里有 **50 个**无名可交互控件。去重后是 8 类真缺陷：

| 控件 | 实测 | 问题 |
|---|---|---|
| `看已处理的` 开关 | `AXCheckBox 44×20`，label 空 | SwiftUI 把标题画成兄弟节点，开关自己是匿名的 |
| 搜索承诺框 | `AXTextField 914×16`，label 空 | 同一套写法在「待办」「草稿」有名字，这里没有 |
| 浮岛底部两个图标钮 | `12.5×11` / `13×10` | 无内边距，可点区就是字形 |
| 页脚刷新 | `11.5×14`，help 空 | 15 个页面都一样 |
| 模型列表箭头 | `10.5×6` | 全应用最小的目标 |
| `s 展开模型列表` 刷新 | `12×14` | 同上 |

**修复后**：23 次启动、1189 个控件里 **iconOnly=0、smallIcons=0**。

修的是「图标钮的可点区」，不是图标本身：字形仍是 10–13pt，外面套 22pt 的 frame +
`contentShape(Rectangle())`。22pt 是 macOS 标准按钮高度。

### 2.2 对比度：jade 当文字色用（14 个页面）

`CompanionPalette.jade`（#16776C）是**浅色外观**的颜色。
当**填充**用两种外观都对（白字压在 jade 上 5.5:1）；
当**文字**压在深色卡片上就只有 **3.08:1**。

实测（选项卡 system / autopilot 等）：
`已就绪` / `设置 AI` / `查看待确认回复` 画成 `rgb(56,117,108)` 压在 `#1F1F1F` 上 = **3.08:1**，
而同一张卡上的正文是 5.9–12.3:1 —— 强调层级是唯一读不出来的那一层。

**修法**：新增 `CompanionPalette.jadeInk`（= 方案感知的 accent，深色下是薄荷），
把 **55 处** `foregroundStyle(...jade)` 换成它；填充、描边、图标底色继续用 `jade`。

**实测对比**：

| | 修复前 | 修复后 |
|---|---|---|
| 深色卡片上的强调文字 | 3.08:1 | **9.61:1** |

**补的门**（`CompanionMaterialTests`，+3 条，共 24 条）：
`jadeInk` 在深色卡上必须 ≥ AA；`jade` 本身必须**仍然不过**（记录为什么有两个名字）；
以及扫源码禁止 `foregroundStyle(CompanionPalette.jade)` 回流。第三条**验证过能失败**。

### 2.3 `.tertiary` 承载正文（2.27:1）

`.tertiary` 深色下约 `#565656`，压在 `#1E1E1E` 上是 **2.27:1**，远低于 AA 的 4.5。
全站 11 处 `.tertiary` 里，9 处是 chevron 或 ⌘F 提示（装饰，正确），
**2 处是用户必须读的句子**：

- 「当前只显示还没做完的。过期太久的会收起，不占这个列表。」
- 「这是助手从聊天里整理的，只改这里不会改微信原文。」

第二句是"改这里不会动微信"的保证 —— 读不到就等于没有。两处改 `.secondary`（实测 5.9–12.3:1）。

**补的门**：扫源码，`.tertiary` 不许挂在长文本上（保留 chevron / `·` / ⌘提示）。

### 2.4 破坏性操作没有破坏性样式

「取消」（记录回溯里的承诺）实测 **34×13pt**，与「完成」相距 **8.5pt**，
且是中性灰、**无二次确认** —— 一次误点就丢掉助手从用户自己消息里认出来的承诺。

**修法**：`role: .destructive` + 红色 + 确认弹窗（文案复用既有的
`cancelCommitmentTitle` / `cancelCommitmentMessage`），两个按钮升到 `.small` + 22pt。

「删除草稿」同样：在四个同款灰底按钮里与「复制」长得一模一样，而它不可撤销。
加 `role: .destructive` + 红色（确认弹窗本来就有）。菜单里的同名项一并加上。

**补的门**：`ControlConventionTests`，扫「删除草稿」必须带 `role: .destructive`。**验证过能失败**
（报 `ReplyDraftsView.swift:277 deletes a draft without role: .destructive`）。

### 2.5 全宽填充主按钮（iOS 模式）

待办详情页的「标记完成」是 `Text(...).frame(maxWidth: .infinity)` 配
`.borderedProminent` —— 标题 4 个字，按钮 **436×28pt**，宽度由面板决定。
macOS 的推按钮按标题定宽、靠行的一侧对齐。

**修法**：去掉 `maxWidth: .infinity`，改在按钮上加 `.frame(maxWidth: .infinity, alignment: .trailing)`，
让它靠右而不是被拉满。

**补的门**：`ControlConventionTests` 扫「`frame(maxWidth: .infinity)` 出现在
`borderedProminent` 的 label 里」。这个门也**验证过能失败**（第一版回溯窗口太短，
插进注释后就瞎了；改成扫 20 行并跳过注释行才成立）。

### 2.6 一屏两个填充强调按钮

「聊天回顾」页头部是薄荷填充的「重新分析」，同屏卡片里又有深玉填充的「查看待办」，
**两个主操作、两种色相**，眼睛没有排序依据。

**修法**：卡片的「查看待办」改 `.bordered`，与头部已有的两个文字链一致；
填入式主操作只留一个。

### 2.7 `SettingsSection` 内部对齐（一处根因，四个页面）

`SettingsSection` 内层 `VStack` 没写 alignment，默认 `.center`，
于是**任何不自撑的子视图都会居中**。实测：提醒方式的脚注在
卡片 `x528–2444`（行都从 `x561` 起）里落在 `x1168–1791` —— 一个飘在左对齐卡片中间的文本块。
同样的还有自动回复「哪些一定交给你」、AI 分析与建议的横幅脚注、使用偏好。

**修法**：`VStack(alignment: .leading)` + `.frame(maxWidth: .infinity, alignment: .leading)`。

### 2.8 同一面板把同一个事实说两遍

「关注谁」的详情里「关注级别」出现两次，标签一字不差：只读行（整理范围）
与可编辑分段控件（操作）。留可编辑的那个 —— 它是用户能动手的那个。

**补的门**：`ControlConventionTests` 断言两者不同时存在。

---

## 三、测量本身修掉的两个坑

### 3.1 `--preview-hold-island` 制造了它要拍的缺陷

独立评审把浮岛扩展态拍成"560×252 的纯黑板子，只有两个字形，最大亮度 36/255"，
并且**对不上同一次运行的 AX 转储**，因此标为"低置信、待定"。

自己复现后确认：**是预览开关的竞态，不是产品缺陷**。

- `--preview-hold-island` 在 `applicationDidFinishLaunching` 里**内联**调用 `goExtended()`，
  此时面板还没布局第一帧；
- 扩展态的高度来自内容自己通过 `SizePreferenceKey` 上报的尺寸，
  而该上报在 `panelState.isReady == false` 时被 sink 丢弃；
- 于是窗口停在兜底尺寸、内容没画 —— 黑板子。

实测证据：同一次运行的 `reportSize state=compact size=(297.0×32.0) ready=false`
紧跟 `reportSize state=extended size=(560.0×252.0) ready=true`，
即状态翻转发生在布局之前。

**修法**：把 `goExtended()` 推迟到下一个 runloop turn（`--preview-expand-row` 本来就是这么做的），
并把调用点移到 `isReady = true` 之后。修复后同一开关拍到的就是真实收件箱。

**为什么值得记**：一个会制造它所拍摄的缺陷的预览开关，比没有开关更糟 ——
它让评审写出了一份指向产品的假报告。

### 3.2 抓帧靠跨进程通知，跑不通

原有的 `导出界面快照` 依赖 `DistributedNotificationCenter`，
脚本发出的通知在本机 macOS 上**收不到**，于是自动化走查无法进行。
新增 `--preview-capture=<秒>`（进程内定时）与 `--preview-hig-audit=<秒>`，
把指针和 IPC 一起从回路里去掉。

### 3.3 窗口归属猜错

第一版按 AX 标题给窗口命名，而浮岛与引导窗的 AX 标题都是空的 ——
报告里所有控件都写成 `window`，读者无法知道 12pt 的目标在**哪个窗口**里，
而那正是唯一可操作的信息。改为用 AX 窗口的 frame 与 AppKit 窗口比对认领。

同一版里还漏掉了：滚动条的 11×107 箭头、窗口红绿灯按钮（Apple 自己的控件、Apple 自己的尺寸）、
以及 0×0 的退化 frame（不可点，其尺寸说明不了任何事）。三者都会淹没真正该修的发现。

---

## 四、最终验证

- `swift build`：**0 error 0 warning**。
- `swift test`：全绿（含本轮新增 `MainMenuWiringTests` 4 条、
  `KeyboardShortcutPolicyTests` 9 条、`ControlConventionTests` 4 条、
  `CompanionMaterialTests` 新增 3 条）。
- 本轮新增的 4 个门**逐个验证过能失败**（见上文各节）。
- 23 次启动的进程内测量：**菜单栏六项全部在位**、**iconOnly=0**、**smallIcons=0**。
- 深浅两种外观都跑了（`light-today` / `light-system` / `light-island`）。

## 五、明确边界（未做 / 未验）

- **HIG 原文直连不可用**：`developer.apple.com` 在本机网络下解析到非公网地址，
  条款内容以公开镜像与仓库既有的 8 条清单为准，未逐字引用原文。
- **命中区仍小于 24pt 的文字控件**：剩余 40 类，绝大多数是 macOS 本来就只有
  15–16pt 高的文字链接/分段标签（Apple 自己的 link 就是 15pt）。**没有当作缺陷批量改**，
  因为把平台的默认尺寸判成缺陷会淹掉真正的问题。已单独处理的只有
  图标钮（22pt）、承诺「完成/取消」（22pt）、模型箭头（22pt）。
- **`--preview-hold-island` 之外的浮岛过渡帧率**：本轮未重测，
  沿用 `docs/qa/2026-09-15-frontend-quality-pass.md` 第三轮的九条腿 60 FPS 数据。
- **`.tertiary` 之外的次要文字层级**：只量了被举报的两处正文，未做全站对比度普查。
