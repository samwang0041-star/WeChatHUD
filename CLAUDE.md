# WeChatHUD

macOS 原生吸顶浮窗客户端，配合 wechat-cli 使用。SwiftUI + AppKit。

## 项目状态

**当前阶段：Phase 1 Foundation — 准备开始实现**

- 设计 spec 已完成：`docs/2026-04-11-wechathud-design.md`
- 实现计划已完成：`docs/superpowers/plans/2026-04-11-wechathud-phase1.md`
- 12 个 Task，从脚手架到可运行的 app
- 尚未开始写代码，所有 Task 都是 pending

## 继续工作

1. 读 `docs/superpowers/plans/2026-04-11-wechathud-phase1.md` 获取完整实现计划
2. 从 Task 1（项目脚手架）开始，按顺序执行
3. 推荐使用 subagent-driven-development 或 executing-plans skill

## 关键决策

- **数据来源**：直接读微信加密 DB（移植自 Python CLI 的解密逻辑），不依赖 CLI 运行
- **自有数据库**：`~/.wechat-hud/hud.sqlite3` 存白名单、设置、缓存
- **AI 接口**：可配置的 OpenAI 兼容 API（Ollama/远程都支持）
- **窗口**：NSPanel (.nonactivatingPanel, .floating)，不抢焦点
- **白名单驱动**：只分析白名单里的对话，其余忽略
- **三态**：compact(36px) → notification(90px) → detail(500px)

## 参考

- Python CLI 源码（解密/读取逻辑参考）：`/Users/yuriwong/wechatcli/repo/wechat_cli/core/`
- 已有的 WeChatRadar 项目（不使用，仅参考 Models）：`/Users/yuriwong/wechatcli/WeChatRadar/`

## 构建

```bash
swift build          # 编译
make app && make run # 打包成 .app 并运行
swift test           # 跑测试
```
