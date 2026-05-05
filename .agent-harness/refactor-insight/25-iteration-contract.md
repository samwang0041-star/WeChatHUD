# Iteration Contract — M4: Final Cleanup

## Cycle Goal
1. Extract `ChatInsightService` from `InsightCoordinator.analyzeEntry()` to complete the service-layer separation.
2. Reorganize insight-related service files into `Services/Insight/` subdirectory.
3. Full build verification.

## Deliverables
- New: `Sources/WeChatHUD/Services/Insight/ChatInsightService.swift`
- Modified: `Sources/WeChatHUD/Services/Insight/InsightCoordinator.swift`
- Moved: All insight service files into `Services/Insight/`

## Acceptance Criteria
- [ ] `ChatInsightService` extracted with `analyzeEntry(entry:selfUsername:selfDisplayName:) async -> ChatInsightResult?`
- [ ] `InsightCoordinator.analyzeEntry()` delegates to `ChatInsightService`
- [ ] Insight service files live in `Services/Insight/`: AIChatInsight, ChatStatsEngine, ChatInsightService, InsightCoordinator, InsightStore, InsightRadar, InsightDataLoader
- [ ] `swift build` passes with zero errors
- [ ] No duplicated data-preparation logic remains in coordinator

## Verification Method
1. `swift build` — zero errors
2. Read `ChatInsightService.swift` — verify it contains message loading, formatting, memory loading, alias building
3. Read `InsightCoordinator.swift` — verify `analyzeEntry` is a thin delegation
4. `ls Services/Insight/` — verify file organization

## Out Of Scope
- Modifying view files
- Modifying data models
- Modifying prompt templates

## Ownership
- Generator writes: ChatInsightService.swift, InsightCoordinator.swift, directory reorganization
- Evaluator verifies: build success, code review, directory structure

## Stop Condition
- Pass: all acceptance criteria met
- Fail: build breaks and cannot be fixed within this cycle

## Agreement Status
AGREED

## Negotiation Log
- Generator: Proposed extracting ChatInsightService and reorganizing directory
- Evaluator: Accepted — this completes the service-layer separation and addresses the naming/organization issues from the original spec
