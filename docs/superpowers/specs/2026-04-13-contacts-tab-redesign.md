# 联系人页面重构：二级 Tab + AI 扫描改造

## 背景

ContactsSettingsView 把通讯录列表、AI 白名单扫描、忽略发送人管理全塞在一个滚动页面里，功能局促。AI 扫描存在两个问题：忽略状态不持久（重启丢失）、逐个调 AI API 太慢。

## 设计

### 1. 二级 Tab 拆分

在联系人页面 hero header 下方加 segmented picker，拆为三个 Tab：

| Tab | 标识 | 内容 |
|-----|------|------|
| 通讯录 | `.contacts` | VIP/白名单/灰名单列表、搜索、添加、编辑 |
| AI 扫描 | `.aiScan` | 扫描按钮 + 候选结果 + 已忽略联系人管理 |
| 屏蔽规则 | `.blockRules` | per-chat 忽略发送人列表 + 取消忽略 |

实现方式：`ContactsSettingsView` 内部增加 `@State private var selectedTab` 枚举，用 `Picker` (segmented style) 切换，每个 Tab 内容占满剩余空间。

### 2. 持久化扫描忽略

HUDStore 新增 `scan_dismissed` 表：

```sql
CREATE TABLE IF NOT EXISTS scan_dismissed (
    username TEXT PRIMARY KEY,
    display_name TEXT NOT NULL DEFAULT '',
    dismissed_at TEXT NOT NULL DEFAULT (datetime('now'))
)
```

新增方法：
- `dismissScanResult(username:displayName:)` — 插入忽略记录
- `undismissScanResult(username:)` — 删除忽略记录（下次扫描会再出现）
- `loadDismissedScanResults() -> [ScanDismissedEntry]` — 加载已忽略列表
- `isDismissedFromScan(username:) -> Bool` — 查询是否已忽略
- `dismissedScanUsernames() -> Set<String>` — 批量查询，供 scanCandidates 过滤

### 3. scanCandidates 排除已忽略

`ChatMonitor.scanCandidates()` 在现有的白名单过滤之外，额外排除 `store.dismissedScanUsernames()`。

### 4. 批量 AI 分类

替换当前的逐个 API 调用，改为：

1. 本地通过 `reader.topActiveContacts()` 按活跃度排序取候选（排除白名单 + 已忽略）
2. 对每个候选取最近 5 条消息（减少 token 用量）
3. 一次 API 请求，prompt 包含所有候选人信息，要求返回 JSON 数组
4. 解析结果，按分类（工作/生活/其他）分组展示

单次请求的 prompt 结构：
```
对以下联系人进行分类，判断是否应加入白名单。
每个联系人给出: category(work/life/other), should_whitelist(bool), reason(一句话)。
返回 JSON 数组。

---
1. 张三 (个人聊天, 近45天32条消息)
最近消息:
[张三] 明天会议几点
[我] 下午3点
...

2. 某某群 (群聊, 近45天120条消息)
最近消息:
...
```

fallback：如果候选人超过 15 个，分批（每批 15 个）发送，避免单次 token 过长。

### 5. AI 扫描 Tab 布局

```
┌─────────────────────────────────────────┐
│ [开始扫描]              扫描进度条(如有) │
├─────────────────────────────────────────┤
│ 扫描结果 (N 条建议)     [全部接受] [全忽略]│
│ ┌─ 工作 ──────────────────────────────┐ │
│ │ 张三  32条/45天  "明天会议几点"  [+][×]│ │
│ │ 李四  18条/45天  "合同发你了"    [+][×]│ │
│ └─────────────────────────────────────┘ │
│ ┌─ 生活 ──────────────────────────────┐ │
│ │ 王五  25条/45天  "周末爬山吗"    [+][×]│ │
│ └─────────────────────────────────────┘ │
├─────────────────────────────────────────┤
│ 已忽略 (M 人)                  [展开/收起]│
│ ┌─────────────────────────────────────┐ │
│ │ 赵六  2026-04-10忽略  [加入白名单][删除]│ │
│ └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

- `[+]` = 加入白名单（弹出角色选择）
- `[×]` = 忽略（持久化到 scan_dismissed）
- 已忽略列表中「删除」= 从 scan_dismissed 移除，下次扫描会再出现

### 6. 文件变更清单

| 文件 | 变更 |
|------|------|
| `HUDStore.swift` | 新增 `scan_dismissed` 表 + CRUD 方法 |
| `ChatMonitor.swift` | `scanCandidates()` 排除已忽略 |
| `AIWhitelistCategorizer.swift` | 新增 `categorizeBatch()` 批量分类方法 |
| `ContactsSettingsView.swift` | 拆为三个二级 Tab，通讯录部分保留现有逻辑 |
| `WhitelistScanView.swift` | 重写：批量扫描 + 分组展示 + 已忽略管理 |

### 7. 数据模型

```swift
struct ScanDismissedEntry: Identifiable {
    var id: String { username }
    let username: String
    let displayName: String
    let dismissedAt: Date
}

// 批量分类结果（替换原有逐个 Suggestion）
struct BatchScanResult: Identifiable {
    var id: String { username }
    let username: String
    let displayName: String
    let isGroup: Bool
    let recentCount: Int
    let category: String        // work/life/other
    let shouldWhitelist: Bool
    let reason: String
}
```
