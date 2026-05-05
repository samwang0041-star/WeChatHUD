# Product Spec: Fix Insight Time Model

## Problem Statement
The insight feature has a broken mental model around time ranges:
1. DatePicker in detail view shows a date but AI always analyzes "today" regardless
2. Time window selector (today/7d/30d/90d/all) affects stats but NOT AI analysis
3. User cannot analyze historical days — the feature appears broken
4. User doesn't understand what the feature is supposed to do

## Outcome
A predictable insight experience where:
- The time window selector controls BOTH stats and AI analysis scope
- The date picker in detail view controls WHICH day's AI analysis runs
- UI clearly labels what is being analyzed and when
- The product purpose is clear from the UI

## Target User
WeChatHUD user who wants to understand their communication patterns and identify action items.

## Scope

### In-Scope
1. Make DatePicker control AI analysis date in detail view
2. Make time window selector control AI analysis scope in overview
3. Add clear time range labels throughout the UI
4. Rename/refocus UI copy to clarify product purpose
5. Update cache key to include date for accurate per-day caching
6. Re-trigger analysis when date changes

### Non-Goals
- Changing prompt templates
- Adding new analysis dimensions
- Removing the overview/dashboard view
- Database schema changes

## Design

### Time Model
```
Overview (InsightOverviewDashboard)
├── Time window selector: today/7d/30d/90d/all
├── Affects: global stats + global briefing + sidebar list
└── AI analysis runs for the selected window's messages

Detail (ChatInsightDetailView)
├── Date picker: specific day
├── Affects: which day's messages are AI-analyzed
├── Stats shown for that specific day
└── Clear label: "分析 2024-05-05 的对话"
```

### Key Flow Changes
1. User clicks person in sidebar → triggers analysis for selected date (default today)
2. User changes date in detail → re-triggers analysis for new date
3. Time window changes in overview → reloads stats and global briefing

## Acceptance Criteria
- [ ] DatePicker in detail view actually changes which day's messages are analyzed
- [ ] Changing date re-triggers AI analysis (with loading state)
- [ ] Time range is clearly labeled in detail view header
- [ ] Time window selector affects sidebar session list
- [ ] Build passes

## Risks
- Cache invalidation: per-day cache means more AI calls
- Date edge cases: timezone handling
- Performance: analyzing 7d/30d of messages is slower
