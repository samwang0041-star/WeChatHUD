# WeChatHUD

macOS 原生吸顶浮窗客户端，配合 wechat-cli 使用。SwiftUI + AppKit。

## 项目状态

**当前阶段：Production-ready — 六轮进化完成**

- 194 个测试全部通过（117 基线 + 77 新增）
- Release build 零警告
- ChatMonitor 从 1690 行重构为 1131 行 Coordinator 模式

## 架构概述

```
Sources/WeChatHUD/
├── App/
│   ├── AppDelegate.swift         — 应用入口、panel 创建、keyboard shortcuts
│   ├── FloatingPanel.swift       — NSPanel 子类，浮窗配置
│   └── PanelState.swift          — 三态状态机 + 对话选择路由
├── Data/
│   ├── Models.swift              — 所有数据类型
│   ├── HUDStore.swift            — app 自有 SQLite (设置、白名单、缓存)
│   ├── WeChatReader.swift        — 读取微信加密 DB
│   ├── WeChatDecryptor.swift     — AES-256-CBC 页解密
│   └── WeChatParser.swift        — 消息内容解析 (XML, zstd)
├── Services/
│   ├── ChatMonitor.swift         — 核心协调器 (事件→扫描→UI更新)
│   ├── ScanEngine.swift          — 纯函数扫描逻辑 (从 ChatMonitor 提取)
│   ├── MessageHelpers.swift      — 纯工具函数 (从 ChatMonitor 提取)
│   ├── AIService.swift           — OpenAI 兼容 API 客户端
│   ├── AIClassifier.swift        — 消息分类 (ask/task/deadline)
│   ├── ReplyDebtScorer.swift     — 回复债务评分
│   ├── ReplyDebtJudge.swift      — AI 二次判断 + shadow mode
│   ├── AutopilotService.swift    — 自动回复编排 (带安全护栏)
│   ├── AutoReplyGenerator.swift  — AI 回复生成
│   └── ... (11 个 AI service 共计)
└── Views/
    ├── HUDRootView.swift         — 顶层路由 (compact/extended/notification/detail)
    ├── CompactBarView.swift      — 紧凑模式 (36px)
    ├── ExtendedTabsView.swift    — 展开模式 (多标签页)
    ├── CatchupTabView.swift      — 追赶模式 (三段式优先级摘要)
    ├── CommitmentTabView.swift   — 承诺管理 (完成/取消操作)
    ├── ConversationDetailView.swift — 对话分析工作台
    ├── DailyReportTabView.swift  — 日报/周报 (带切换)
    └── NotificationBannerView.swift — 通知横幅 (带操作按钮)
```

## 关键决策

- **数据来源**：直接读微信加密 DB（AES-256-CBC 页解密），不依赖 CLI
- **自有数据库**：`~/.wechat-hud/hud.sqlite3` 存白名单、设置、缓存
- **AI 接口**：可配置的 OpenAI 兼容 API（Ollama/远程都支持）
- **窗口**：NSPanel (.nonactivatingPanel, .floating)，不抢焦点
- **白名单驱动**：只分析白名单里的对话，其余忽略
- **三态 + 详情**：compact(36px) → extended(tabs) → notification(banner) → detail(500px)
- **Autopilot 安全**：敏感词检测 + 会话发送上限 + 置信度阈值 + 高风险人工确认

## 构建

```bash
swift build          # 编译 (debug)
swift build -c release  # 编译 (release, 零警告)
make app && make run # 打包成 .app 并运行
make test            # 跑测试 (194 个, 过滤输出只显示结果)
swift test           # 跑测试 (完整输出)
```

## 测试

194 个测试覆盖：
- HUDStore (45): 设置/白名单/PendingAsk/Autopilot/AIAudit/ChatAction
- NewSchema (24): Contact/VIPTrace/RecalledMessage/Commitment
- WeChatDecryptor (9): 页解密 + 端到端 DB 解密
- WeChatParser (8): 内容解码/XML 解析/媒体渲染
- MessageHelpers (23): 纯函数全覆盖
- AutopilotSafety (15): 安全护栏配置 + 关键词检测
- AI Services (70+): Classifier/ReplyDebt/Commitment/VIP/Context 等

## 参考

- Python CLI 源码（解密/读取逻辑参考）：`/Users/yuriwong/wechatcli/repo/wechat_cli/core/`
- 设计 Spec：`docs/2026-04-11-wechathud-design.md`
- 进化日志：`docs/evolution-log.md`
