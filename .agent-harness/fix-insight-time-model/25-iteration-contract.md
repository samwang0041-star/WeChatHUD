# Iteration Contract — Fix Insight Time Model

## Cycle Goal
Make the DatePicker in ChatInsightDetailView actually control which day's messages are AI-analyzed. Add clear time range labeling. Ensure re-analysis triggers when date changes.

## Deliverables
- Modified: AIChatInsight.swift — accept date range instead of hardcoded "today"
- Modified: ChatInsightService.swift — pass date parameter
- Modified: InsightCoordinator.swift — pass date through analyzeOneChat
- Modified: ChatInsightDetailView.swift — trigger re-analysis on date change, show date label
- Modified: ChatInsightView.swift — pass selectedDate to analysis trigger

## Acceptance Criteria
- [ ] AIChatInsight.analyzeChat accepts start/end timestamps for message filtering
- [ ] ChatInsightService.analyzeEntry accepts a Date parameter
- [ ] InsightCoordinator.analyzeOneChat accepts a Date parameter
- [ ] ChatInsightDetailView triggers re-analysis when DatePicker changes
- [ ] Detail view header clearly shows the analysis date range
- [ ] Cache key includes date so per-day caching works correctly
- [ ] Build passes

## Verification Method
1. `swift build` — zero errors
2. Source review: AI analysis no longer hardcodes "today"
3. Source review: DatePicker onChange triggers re-analysis

## Out Of Scope
- Time window selector affecting AI analysis (deferred — needs global briefing changes)
- Overview dashboard time range changes
- UI copy rebranding

## Ownership
- Generator writes: all modified files
- Evaluator verifies: build, source review

## Stop Condition
- Pass: all acceptance criteria met
- Fail: build breaks unfixably

## Agreement Status
AGREED
