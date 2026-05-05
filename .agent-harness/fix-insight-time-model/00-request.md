# Request

## Summary
Fix the insight feature's time/range model so users understand what the feature provides and can control what they're analyzing.

## Intent Expansion
User reports confusion about the insight feature:
1. "进去是分析当天" — entering insight shows analysis for "today" but this is not clearly communicated
2. "选择了某个人之后，到底是分析多少时间区间的，我是没预期的" — when selecting a person, user has no idea what time range is being analyzed
3. "用户搞不懂这个洞察功能到底想提供什么功能" — the overall product purpose is unclear

Current problems:
- The DatePicker in ChatInsightDetailView does NOT affect AI analysis (always analyzes "today")
- The time window selector (today/7d/30d/90d/all) affects stats but NOT AI analysis
- This creates a conceptual mismatch: two time controls that behave differently
- User thinks they can analyze historical days but cannot

Desired outcome:
- Clear product positioning: what is insight for?
- Predictable time model: when user selects a date or time range, AI analysis respects it
- UI communicates clearly what is being analyzed and when

## Delivery Mode
standard (focused UX fix, not a large refactor)

## Handoff Workspace
/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/fix-insight-time-model

## Constraints Digest
- SwiftUI + macOS
- Must not break existing data models
- AI analysis via AIChatInsight currently hardcodes "today"
- Analysis cache uses input hash including messages
- Must maintain backward compatibility where possible

## Assumptions
- User wants to analyze arbitrary days (not just today)
- Time window selector should affect both stats and AI analysis
- Date picker should actually control which day's AI analysis runs
- Product positioning: "通信洞察" = understand your communication patterns and identify actions needed

## Autonomy Budget
- May infer: reasonable UI labels, time range logic
- May inspect: all Swift source files
- May change: View files, Service files (AIChatInsight, ChatInsightService, InsightCoordinator)
- Must ask before: removing core features, changing database schema

## Question Policy
Ask only for blocking ambiguity. Otherwise proceed with explicit assumptions.

## Role Permissions
- Planner: read-only / spec only
- Generator: write scope
- Evaluator: read-only verification

## Stop Conditions
- All acceptance criteria met
- Build breaks and cannot be fixed
- Same substantive failure twice

## Validation Expectations
- swift build passes
- UI clearly communicates analysis time range
- Date picker actually affects AI analysis
- Time window selector affects both stats and AI
