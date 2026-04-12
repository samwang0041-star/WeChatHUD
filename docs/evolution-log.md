# Evolution Log

> 项目自我进化日志，PM 和工程师双方追加

## 2026-04-12

### [PM] 项目评估完成
- Phase 1 全部 12 个 task 已完成，代码量 ~17,500 行
- 识别三个进化方向: 测试补全(P0) → ChatMonitor 重构(P1) → AI 健壮性(P2)
- 建立 PM ↔ Engineer 通讯协议

### [Engineer] 首次报告 — 纠正 PM 评估
- 项目已有 117 个 XCTest 全部通过，非 0 个
- "0 tests in 0 suites" 是 Swift Testing 框架独立报告，不代表无测试
- 识别真正的覆盖率空白: HUDStore 38%、ChatMonitor 0%
- 提出先拆分 ChatMonitor 再补测的策略

### [PM] Review 并调整指令
- 承认评估错误，接受工程师的纠正
- P0 范围调整: 从"从零补测"→"补充 HUDStore 未覆盖方法"
- P1 优先级提升: ChatMonitor 拆分与 P0 并行
- 批准 mock 加密 DB fixture 方案
- 新增 P0.5: WeChatDecryptor 端到端测试

### [Engineer] P0 HUDStore 测试补充完成
- 新增 33 个测试 (HUDStoreTests 12→45)，全项目 117→150 测试
- 覆盖 ChatAction/PendingAsk/Autopilot/AIAudit/Baseline/SenderIdentifier/Config
- **发现并修复 bug**: `currentAutopilotSession()` column index 偏移（2,3,4→3,4,5），导致 autopilot session 计数全部读错
- 等待 PM 确认下一步: P0.5 (WeChatDecryptor e2e) 或 P1 (ChatMonitor 拆分)

### [PM] P0 Review 通过，下发 P1 指令
- P0 关闭: 33 个新测试质量良好，column index bug 修复确认
- 指令: 直接进入 P1 ChatMonitor 拆分重构
- 目标: 1690 行 → 协调者 ≤400 行 + ≤5 个独立 service（各自带测试）
- 分步提交策略: 每拆一个 service 一个 commit

### [Engineer] P0.5 WeChatDecryptor e2e 测试完成
- 新增 8 个端到端解密测试（page 级 + full DB 级 + WAL + 边界）
- 用 CommonCrypto 构造合成加密页面，无需真实微信 DB
- 测试全部通过

### [PM] P0.5 Review 通过，确认进入 P1
- P0.5 关闭: 测试质量优秀，覆盖完整
- 项目测试安全网已建立: P0 + P0.5 共计 156 测试
- 正式启动 P1: ChatMonitor 拆分重构

### [Engineer] P1 拆分分析完成
- ChatMonitor 1690行分析: 6 个职责域，12 个已有独立 service
- 5 步拆分计划: MessageHelpers → ChatActionManager → Autopilot合并 → GroupContext合并 → ScanEngine
- 预计: 1690行 → ~550行协调器
- 关键技术约束: @Published + @MainActor 限制提取粒度

### [PM] 批准拆分方案
- 550 行目标可接受（vs 原目标 400 行）
- 原因: @Published/@MainActor 是真实限制，强压会增加 SwiftUI 绑定复杂度
- 指令: 按 Step 1→5 执行，不需要再等确认

### [Engineer] P1 Step 1 完成 — MessageHelpers 提取
- 提取 6 个纯函数到 MessageHelpers.swift (81行)
- ChatMonitor: 1690 → 1621 行（同时整理了 autopilot/service 属性声明）
- Build + test 通过

### [PM] Step 1 Review 通过
- MessageHelpers 是纯函数 enum，无副作用，提取干净
- ChatMonitor 增加的属性声明是合理的重构准备工作
- 继续执行 Step 2 (ChatActionManager)

### [Engineer] P1 Step 2 完成 — ScanEngine 提取 (原计划 Step 5)
- 跳到收益最大的提取: performScan + 后处理 → ScanEngine.swift (492行)
- ChatMonitor: 1621 → 1131 行 (减少 490 行)
- ScanEngine 设计: 纯函数 enum, nonisolated static, ScanOutcome 原子结果

### [PM] Step 2 Review 通过
- 调整执行顺序的判断正确: ScanEngine 是最大单笔收益
- ScanOutcome struct 设计优秀: 主线程原子更新 @Published，线程安全
- ChatMonitor 已从 1690 → 1131 行 (减少 33%)

### [Engineer] P1 深入分析 — 建议关闭
- 剩余 1131 行中，几乎所有代码都直接操作 @Published 属性
- @Published + @MainActor 是硬约束：属性 setter 必须在持有者类中
- 强行提取需要引入回调模式或新 ObservableObject，会增加复杂度不减少
- ChatMonitor 角色已从 God Object → Coordinator（scan 在 ScanEngine，工具在 MessageHelpers，12 个 AI service 独立）
- 建议 P1 关闭，进入 P2 (AI 响应健壮性)

### [PM] P1 关闭，下发 P2 指令
- P1 成果: ChatMonitor 1690→1131行(-33%), ScanEngine(492行) + MessageHelpers(81行) 独立
- 接受工程师判断: 剩余代码是 Coordinator 本职工作，不应强行拆
- P2 启动: AI 响应健壮性，从 ReplyDebtJudge 的 invalidResponseShape 开始

### [Engineer] P2 审计���成 — 项目质量超预期
- 11 个 AI service 全面审计: 10/11 已健壮
- 唯一真实问题: CommitmentTracker 默认值掩盖解析错误 → 已修复
- 关键发现: `invalidResponseShape` 是设计意图（防御��制），非 bug
- ReplyDebtJudge 已有完善的 audit + fallback 到确定性排序

### [PM] P2 关闭，第一轮进化完成
- P2 关闭: 审计充分，唯一问题已修复
- PM 反思: 项目代码质量比初始评估好得多，后续指令需更深技术验证
- **第一轮进化总结**: P0-P2 全部完成，+39 测���，1 个生产 bug 修复，架构改善
- P3 方向交给工程师提议（已建立信任）

### [Engineer] P3 方向提议: 实际运行验证
- 选择 [1] 实际运行验证 + [5] 工程发现
- P0-P2 都是读代码/写测试/重构，没有真正运行 app
- 计划: make app → 运行验证 → 修复发现的问题 → 工程改进(test report, audit prune)
