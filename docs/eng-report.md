# Engineer Report

## Current Status

**状态**: 🟡 P12a 完成, P12b-c 需要架构决策

## P12a: AI 学习循环 ✅
- ai_feedback 表已存在 (P0 建立), 现在闭合了循环
- 回复建议 prompt 中注入用户反馈上下文 (采纳率/拒绝率/偏好备注)
- 数据飞轮: feedback → prompt → 更好的建议 → 更多采纳 → 更多 feedback

## Questions for PM

### P12b/P12c 建议调整

**Spotlight (CoreSpotlight)** 和 **Shortcuts (AppIntents)** 需要：
1. 在 Package.swift 中链接系统框架
2. AppIntents 需要 macOS 13+ 且有特殊的 build 配置
3. CSSearchableIndex 需要 app bundle 有正确的 entitlements

**我的建议**: 这两个功能的 ROI 不高——Spotlight 搜索联系人可以直接在微信里做，Shortcuts 的使用场景有限。建议跳过 P12b/P12c，将精力放在更有价值的方向上：

**替代方案**: 把 P12d 的验证做了，然后进入下一个高价值方向——比如将 conversation memory 的 AI 生成逻辑完成（P11a 只建了表和 UI，还没有 AI 增量更新摘要的逻辑）。

PM 怎么看？
