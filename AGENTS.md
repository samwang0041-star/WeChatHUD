# WeChatHUD

macOS 原生吸顶浮窗客户端，配合 wechat-cli 使用：SwiftUI + AppKit，直接读微信加密 DB 提供收件箱、AI 分析与自动回复。

## 项目状态（2026-09-12 全代码对抗性质检后）

- Production-ready。测试数量以 `swift test` 输出为准，不写死人肉统计（防的是：旧统计数字失真误导判断）。
- 未跑的用例都是显式门禁：无本地微信库 / 无 live AI 端点 / `WCHUD_LIVE_COMPANION_AI=1` 未设置的 live 验收——跳过是显式 skip，不是静默不收集。
- Codex 集成：读 codex CLI 本地 OAuth token 调 gpt-5.4。
- 对抗性质检报告与执行记录：`docs/qa/2026-09-12-adversarial-full-code-audit.md`（多分片消息读取、游标积压、外源数值转换崩溃、自更新签名校验、/tmp 隐私日志、回溯脱敏等 P0/P1 已修复并补测试）。

## 架构与文档路由（改 X 时读 Y）

| 改什么 | 入口 |
|---|---|
| 应用入口 / 浮窗 / 三态路由 | `Sources/WeChatHUD/App/`（`AppDelegate`、`FloatingPanel`、`PanelState`） |
| 数据模型与自有 SQLite | `Data/Models.swift`、`Data/HUDStore.swift`（`~/.wechat-hud/hud.sqlite3` 存白名单、设置、缓存） |
| 微信库读取链路 | `Data/WeChatReader.swift`（AES-256-CBC 页解密）、`WeChatDecryptor.swift`、`WeChatParser.swift` |
| 事件→扫描→UI 核心链路 | `Services/ChatMonitor.swift`；纯函数扫描在 `ScanEngine.swift`、`MessageHelpers.swift` |
| AI 调用 | `Services/AIService.swift`（OpenAI 兼容 API，Ollama/远程均可）+ `Services/Codex/`（`CodexAuth` 读 `~/.codex/auth.json`、`CodexTokenStore`、`CodexBackend` 直连 chatgpt.com/backend-api） |
| 自动回复护栏 | `Services/AutopilotService.swift` + `SafeNumber.swift` |
| UI | `Views/`（`HUDRootView` 顶层路由，compact 36px → extended → notification banner → detail 500px） |
| 领域决策 | 根目录 `CONTEXT.md` + `docs/adr/` |
| Issue / 标签 / 单仓域文档约定 | `docs/agents/issue-tracker.md`、`docs/agents/triage-labels.md`、`docs/agents/domain.md` |
| UI 动效与交互 | `docs/design/ui-language.md`，动效统一走 `CompanionMotion` |

## 关键事实

- 数据来源是直接读微信加密 DB，不依赖 CLI；只分析白名单里的对话。
- 窗口用 NSPanel（`.nonactivatingPanel`、`.floating`）不抢焦点。
- Python CLI 参考实现（解密/读取逻辑）：`/Users/yuriwong/wechatcli/repo/wechat_cli/core/`。
- 设计 Spec：`docs/2026-04-11-wechathud-design.md`；进化日志：`docs/evolution-log.md`。

## 风险边界（自动发送 Autopilot）

方向是 full-auto + 多层护栏，护栏都在 `ChatMonitor→handleNewMessages→executeSend` 真实链路上执行并有行为测试：

- 默认关闭（`autoSendEnabled=false`）；置信度阈值 0.8；敏感词二级拦截；媒体置信度 0.7x 衰减；每会话发送上限 50 条。
- **金融类（转账/红包/小程序）强制 pending；群聊消息（含 @ 提醒）一律人工确认。** 这两条是不可退让的外发边界。
- 回溯脱敏：发言前被提及的人名、群名、手机号不出网；瞬时 AI 失败不落永久策略。
- 供应链：自更新包未签名 / 被篡改 / TeamID 不匹配一律拒绝安装（AppUpdateSignatureTests 覆盖）。

## 构建与测试

```bash
swift build                 # debug 编译
swift build -c release      # release 编译（要求零警告）
make app && make run        # 打包 .app 并运行
make test                   # swift test 全量
swift test --filter AutopilotSafetyTests   # 跑单个套件
```

测试组织（防的失败写在括号里）：AutopilotSafetyTests / AutopilotGuardrailPipelineTests（自动发送越权外发）、WeChatShardMergeTests / ScanBacklogPagingTests（跨 `message_N.db` 分片丢消息、积压漏扫）、SafeNumberTests / AIJSONExtractorTests / AIRateLimiterTests（外源数值崩溃、AI 输出解析失败）、RetrospectivePrivacyTests / RedactorTests（隐私出网）、AppUpdateSignatureTests（被篡改的更新包）、HUDStore / NewSchema（老库迁移丢数据）、AIAnalysisPipelineTests / Codex 系列（AI 链路假成功、token 刷新失败）。live 验收需 `WCHUD_LIVE_COMPANION_AI=1`。

## 授权与完成

本地开发库与一次性 fixture 上直接跑：编译、跑测试、修掉本次改动引入的失败、重跑受影响套件，每一步不用等我确认。

完成判据：`swift build` 通过；受影响测试套件通过（含新增行为的回归测试）；改动触及自动发送链路时，对应护栏行为测试同步覆盖。
