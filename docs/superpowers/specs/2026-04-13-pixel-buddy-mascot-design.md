# Pixel Buddy — 像素小人陪伴角色

## 概述

在 WeChatHUD 的 compact bar 和 extended inbox header 中添加一个 24x24 像素风格的小人角色。小人根据应用当前状态展示不同的表情和动作，营造"有人陪伴"的感觉。

## 设计决策

- **风格**：像素风（pixel art），24x24 网格
- **实现**：纯 SwiftUI Canvas/Path 绘制 + Timer 逐帧动画，无图片资源
- **架构**：单一 View + State 枚举，不拆分 Model-View
- **位置 compact**：固定在 bar 最右端
- **位置 extended**：移到 inbox header 右侧，和 badge/sync/gear 同行
- **帧率**：3-4fps（每帧 ~250ms）

## BuddyMood 枚举

9 种状态，分 compact 和 extended 两组：

### Compact bar 状态

| Mood | 触发条件 | 动作描述 |
|------|---------|---------|
| `idle` | 一切正常，< 5分钟 | 站立微微呼吸，偶尔眨眼、东张西望 |
| `scanning` | `syncStatus == .syncing` | 拿放大镜在看 |
| `pending` | 有非 P0 待处理消息 | 举小旗挥手提醒 |
| `urgent` | 有 P0 紧急消息 | 跳起来，头上冒感叹号 |
| `error` | syncStatus 为 error/stale/waitingForWeChat | 蹲下来，头上冒问号 |
| `sleepy` | idle 超过 5 分钟 | 坐下来打瞌睡 |

### Extended inbox 状态

| Mood | 触发条件 | 动作描述 |
|------|---------|---------|
| `browsing` | 用户在浏览 inbox 列表 | 站着翻小本子 |
| `analyzing` | AI 正在分析/分类 | 戴上眼镜看文件 |
| `celebrating` | inbox 清空 | 开心举手庆祝 |

## 颜色板

6 种颜色，适配暗色主题：

```swift
enum PixelColor: UInt32 {
    case clear  = 0x00000000  // 透明
    case skin   = 0xFFD4A574  // 肤色
    case hair   = 0xFF2C2C2C  // 深色头发
    case shirt  = 0xFF4A90D9  // 蓝色上衣
    case pants  = 0xFF3C3C3C  // 深色裤子
    case eye    = 0xFF1A1A1A  // 眼睛
    case accent = 0xFFFF6B6B  // 强调色（感叹号、旗子等道具）
}
```

## 帧数据

每个 mood 定义 2-4 帧循环动画。每帧为 `[[PixelColor]]`（24行 x 24列）。

帧数据直接在 `PixelBuddyView.swift` 中作为静态常量定义。用数组字面量描述，一行对应一行像素。

### 动画时序

- 基础帧率：250ms/帧（4fps）
- idle 的眨眼/东张西望：在正常循环中穿插随机触发帧（每 3-8 秒触发一次）
- mood 切换时：重置到新姿势第 0 帧，`.opacity` 过渡

## 渲染

使用 SwiftUI `Canvas` 绘制：

```swift
Canvas { context, size in
    let pixelSize = size.width / 24
    for row in 0..<24 {
        for col in 0..<24 {
            let color = currentFrame[row][col]
            guard color != .clear else { continue }
            let rect = CGRect(x: CGFloat(col) * pixelSize,
                              y: CGFloat(row) * pixelSize,
                              width: pixelSize, height: pixelSize)
            context.fill(Path(rect), with: .color(color.swiftUIColor))
        }
    }
}
.frame(width: 24, height: 24)
```

## Mood 推导逻辑

在使用处直接从 `ChatMonitor` 计算，不额外抽层：

```swift
private var buddyMood: BuddyMood {
    if monitor.stats.syncStatus == .syncing { return .scanning }
    if !syncIsOK { return .error }
    if monitor.inboxItems.contains(where: { $0.priority == .p0 }) { return .urgent }
    if monitor.inboxItems.contains(where: { $0.actionRequired }) { return .pending }
    return .idle  // sleepy 由 idle 持续时间触发
}
```

Extended 模式下根据当前上下文覆盖：
- inbox 列表可见 → `.browsing`
- AI 任务进行中 → `.analyzing`
- inbox 列表为空 → `.celebrating`

### Sleepy 触发

CompactInboxBar 中用 `@State var idleSince: Date?` 追踪：
- mood 变为 `.idle` 时记录 `idleSince = Date()`
- Timer tick 时检查是否超过 5 分钟
- 超过则显示 `.sleepy`

## 文件变更

### 新增

- `Sources/WeChatHUD/Views/PixelBuddyView.swift`
  - `PixelColor` 枚举
  - `BuddyMood` 枚举
  - `PixelBuddyView: View`（Canvas 渲染 + Timer + 帧数据）

### 修改

- `Sources/WeChatHUD/Views/CompactInboxBar.swift`
  - HStack 末尾添加 `PixelBuddyView(mood: buddyMood)`
  - 添加 `buddyMood` 计算属性
  - 添加 `@State var idleSince: Date?` 用于 sleepy 判断
- `Sources/WeChatHUD/Views/InboxView.swift`
  - header 右侧添加 `PixelBuddyView(mood: extendedMood)`
- `compactBarWidth()` — 各宽度值 +30pt

## 测试

- BuddyMood 推导：给定不同的 inbox/sync 状态组合，验证输出 mood 正确
- 可在现有测试套件中新增 ~5 个 case
