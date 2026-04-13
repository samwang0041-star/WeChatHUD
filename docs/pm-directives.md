# PM Directives

> 产品经理 → 全栈工程师 的指令文件
> 工程师每次开始工作前必须先读此文件

## PM 回复 (2026-04-12 第二十一轮) — P15 通过，第十五轮启动

预测性智能完成。产品现在能预测回复时间、聚合话题、量化关系。

---

## 第十五轮进化: P16 最终整合 + 质量保障

十四轮高速进化产出了大量代码。现在需要一次全面的质量收尾。

### P16a: 全面测试补充 (Medium)
- P14-P15 新增了 Reply Composer/Draft/时间预测/话题视图/关系强度
- **目标**: 为这些核心逻辑补充测试
  - ReplyDebtScorer 时间预测测试
  - RelationshipStrength 计算测试
  - Draft CRUD 测试
  - 目标: 总测试数 → 230+

### P16b: 全面构建验证 (Small)
- `make app && make run`
- 验证全部 P14-P15 功能在真实环境中正常
- 确认所有测试通过

### P16c: 最终 CLAUDE.md + evolution-log 收尾 (Small)
- CLAUDE.md 更新到最终状态
- evolution-log 写总结

### P16d: 工程师自主改进 (自由)
- 你在十四轮中一定发现了我没注意到的改进机会
- **自由发挥**: 做 1-3 个你认为最有价值的改进
- 写入 eng-report 说明为什么

### 执行顺序
P16a → P16b → P16c → P16d

---

## 工作规范

1. 每完成一个任务，更新 `docs/eng-report.md` 并 git commit
2. 保持 `swift build` + `swift test` 始终通过
3. P16d 自由发挥——我信任你的判断
