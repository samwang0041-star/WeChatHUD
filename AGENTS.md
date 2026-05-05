# WeChatHUD

macOS 原生吸顶浮窗客户端，配合 wechat-cli 使用。SwiftUI + AppKit。

## 项目状态

**当前阶段：Production-ready — 六轮进化完成 + Codex 集成**

- 350 个测试全部通过（321 基线 + 29 Codex 新增）
- Release build 零新警告（pre-existing Swift 6 严格并发告警未处理）
- ChatMonitor 从 1690 行重构为 1131 行 Coordinator 模式
- Codex 集成：读取 codex CLI 本地 OAuth token，蹭 ChatGPT 订阅调 gpt-5.4

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
│   ├── AIService.swift           — OpenAI 兼容 + Codex 分流入口
│   ├── Codex/                    — OpenClaw 机制复刻 (ChatGPT OAuth 直连)
│   │   ├── CodexAuth.swift       — 读 ~/.codex/auth.json + JWT 解码
│   │   ├── CodexTokenStore.swift — access token 缓存 + refresh + 单例去重
│   │   └── CodexBackend.swift    — chatgpt.com/backend-api SSE 客户端
│   ├── AIClassifier.swift        — 消息分类 (ask/task/deadline)
│   ├── ReplyDebtScorer.swift     — 回复债务评分
│   ├── ReplyDebtJudge.swift      — AI 二次判断 + shadow mode
│   ├── AutopilotService.swift    — 自动回复编排 (带安全护栏)
│   ├── AutoReplyGenerator.swift  — AI 回复生成
│   ├── StyleProfiler.swift       — 用户写作风格学习 (集成到回复建议)
│   └── ... (12 个 AI service 共计)
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
- **AI 接口**：可配置的 OpenAI 兼容 API（Ollama/远程都支持）+ OpenAI Codex (蹭 codex CLI 登录态，指纹完全模拟 OpenClaw/pi-ai：`originator: pi`、`User-Agent: pi (Darwin...)`、同样的 session_id/prompt_cache_key 复用策略)
- **窗口**：NSPanel (.nonactivatingPanel, .floating)，不抢焦点
- **白名单驱动**：只分析白名单里的对话，其余忽略
- **三态 + 详情**：compact(36px) → extended(tabs) → notification(banner) → detail(500px)
- **Autopilot 安全**：敏感词检测 + 会话发送上限 + 置信度阈值 + 高风险人工确认
- **StyleProfiler**：学习用户写作风格，让 AI 回复建议匹配个人习惯
- **Smart Digest**：离开 30 分钟后返回自动提示"你错过了什么"
- **7 日趋势图**：VIP Profile 中的消息活跃度迷你柱状图
- **对话记忆**：每个白名单对话维护滚动摘要，AI 增量更新
- **主动提醒**：4 规则引擎 (VIP超时/承诺到期/连续消息/P0待回)
- **跨对话关联**：检测多个对话中的共同关键词
- **AI 学习循环**：用户反馈驱动回复建议持续优化
- **数据导出**：Markdown 报告导出到桌面
- **首次引导**：4 步 onboarding 向导
- **菜单栏图标**：状态栏未读 badge + 右键菜单

## 构建

```bash
swift build          # 编译 (debug)
swift build -c release  # 编译 (release, 零警告)
make app && make run # 打包成 .app 并运行
make test            # 跑测试 (194 个, 过滤输出只显示结果)
swift test           # 跑测试 (完整输出)
```

## 测试

350 个测试覆盖：
- HUDStore (45): 设置/白名单/PendingAsk/Autopilot/AIAudit/ChatAction
- NewSchema (24): Contact/VIPTrace/RecalledMessage/Commitment
- WeChatDecryptor (9): 页解密 + 端到端 DB 解密
- WeChatParser (8): 内容解码/XML 解析/媒体渲染
- MessageHelpers (23): 纯函数全覆盖
- AutopilotSafety (15): 安全护栏配置 + 关键词检测
- Codex (29): CodexAuth (18) / CodexBackend (6) / CodexTokenStore (5) — OAuth 解析、SSE 解析、HTTP 指纹断言、401 重读、并发 refresh 去重
- AI Services (70+): Classifier/ReplyDebt/Commitment/VIP/Context 等

## 参考

- Python CLI 源码（解密/读取逻辑参考）：`/Users/yuriwong/wechatcli/repo/wechat_cli/core/`
- 设计 Spec：`docs/2026-04-11-wechathud-design.md`
- 进化日志：`docs/evolution-log.md`

## Agent skills

### Issue tracker

Issues live in the repo's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo (one `CONTEXT.md` + `docs/adr/` at root). See `docs/agents/domain.md`.
