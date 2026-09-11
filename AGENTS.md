# WeChatHUD

macOS 原生吸顶浮窗客户端，配合 wechat-cli 使用。SwiftUI + AppKit。

## 项目状态

**当前阶段：Production-ready — 多轮进化 + Codex 集成（2026-09-12 全代码对抗性质检后修正）**

- 1174 个 XCTest 函数 + 70 个 swift-testing 用例、141 个测试文件（历史记录中的 981/519/350/223 均为旧数；具体数字以 `swift test` 输出为准，不要写死人肉统计）
- 全部通过。跳过的用例都是显式门禁：无本地微信库 / 无 live AI 端点 / `WCHUD_LIVE_COMPANION_AI=1` 未设置的 live 验收
- Xcode 26.6 下 debug/release 双构建通过，release 零警告
- ChatMonitor 2957 行；HUDStore 3627 行、Models 2034 行；2026-09-06 那次拆分实际拆出 936 行到 ConversationMemoryUpdater + ChatMonitor+DailyReport + ChatMonitor+OnDemandAnalysis
- Codex 集成：读取 codex CLI 本地 OAuth token，蹭 ChatGPT 订阅调 gpt-5.4
- **Autopilot 方向（2026-09-06 定案，2026-09-12 质检修正）**：full-auto + 多层护栏。默认关闭（`autoSendEnabled=false`），置信度阈值 0.8，敏感词二级拦截，媒体置信度 0.7x 衰减，金融类（转账/红包/小程序）强制 pending，**群聊消息（含 @ 提醒）一律人工确认**，每会话发送上限 50 条。这些护栏都在 ChatMonitor→handleNewMessages→executeSend 的真实链路上执行，并有行为测试覆盖（AutopilotSafetyTests / AutopilotGuardrailPipelineTests）。CONTEXT.md 的自动托管条目已按代码修正。
- **2026-09-12 对抗性质检**：`docs/qa/2026-09-12-adversarial-full-code-audit.md`（报告 + 执行记录）。多分片消息读取、游标积压、外源数值转换崩溃、自更新签名校验、/tmp 隐私日志、回溯脱敏等 P0/P1 已修复并补测试。

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
│   ├── AutopilotService.swift    — 自动回复编排 (带安全护栏)
│   ├── SafeNumber.swift          — 外源数值钳制 (AI/HTTP/AX 数值进入 Int 之前)
│   ├── AutoReplyGenerator.swift  — AI 回复生成
│   ├── StyleProfiler.swift       — 用户写作风格学习 (集成到回复建议)
│   └── ... (12 个 AI service 共计)
└── Views/
    ├── HUDRootView.swift         — 顶层路由 (compact/extended/notification/detail)
    ├── CompactInboxBar.swift      — 紧凑模式 (notch 双翼 + PixelBuddy)
    ├── InboxView.swift            — 展开模式 (统一收件箱，替代旧多标签页)
    ├── InboxRowView.swift         — 收件箱行 (展开露出 ActionPanel)
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
- **Autopilot 安全**：full-auto 方向 — 默认关闭 + 置信度阈值(0.8) + 敏感词拦截 + 媒体衰减(0.7x) + 金融类强制 pending + 会话发送上限(50)
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
make test            # 跑测试 (swift test，完整输出)
swift test --filter AutopilotSafetyTests   # 只跑某个套件
```

## 测试

覆盖范围（数量随迭代变化，别在这里写死人肉统计；总数看 `swift test` 输出）：
- **安全护栏（行为级）**：AutopilotSafetyTests 直接驱动 `applySafetyDowngrades` / `automaticSendHoldReason` / `autopilotSafetyHoldReason`；AutopilotGuardrailPipelineTests 驱动真实 `handleNewMessages`（金融类强制 pending、表情跳过、群聊仅记录、文本只进批处理）
- **消息读取与扫描**：WeChatShardMergeTests（同一会话跨 `message_N.db` 分片归并、按日查询、游标分页）、ScanBacklogPagingTests（游标积压超页上限时向后翻页）、ScanEngineTests
- **外源输入健壮性**：SafeNumberTests（`Int(1e30)` 不再崩进程）、AIJSONExtractorTests（围栏/超长/括号风暴）、AIRateLimiterTests（并发限流）
- **隐私与脱敏**：RetrospectivePrivacyTests（发言前被提及的人名、群名、手机号不出网；瞬时 AI 失败不落永久策略）、RedactorTests
- **供应链**：AppUpdateSignatureTests（未签名/被篡改/TeamID 不匹配一律拒绝安装）
- **存储与模型**：HUDStore、NewSchema（含真实「老库有 whitelist 无 contacts」迁移前置）、AutopilotConfig 宽容解码、DailyReportIdentityTests（跨进程稳定 id）
- **AI 管线**：AIAnalysisPipelineTests（错误详情进审计、空分析不算成功）、Codex 系列（OAuth/SSE/401 重读/refresh token 轮换优先级）、各 AI service 的 prompt 与解析
- **Live 验收**：设置 `WCHUD_LIVE_COMPANION_AI=1` 才执行，未设置时显式 skip（不是静默不收集）

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
