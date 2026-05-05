# 20-evaluation-rubric.md — Daily Report Refactor

## Baseline Dimensions

### 1. Design Quality (weight: 25%)
- Layout hierarchy is clear: metrics → highlights → actions → risks → focus
- Typography uses consistent sizing (11-13pt for content, 9-10pt for labels)
- Color coding is meaningful and consistent with app theme
- Section dividers are subtle but scannable
- No generic card stacks or decorative gradients

### 2. Originality (weight: 20%)
- Output is task-specific, not a generic "dashboard" template
- AI narrative is grounded in user's actual conversations, not boilerplate
- Action prioritization reflects real urgency patterns
- WeChat draft feels personalized, not copy-paste generic

### 3. Craft (weight: 25%)
- Swift code is maintainable, uses existing patterns
- No force unwraps, no implicit optional unwrapping
- Error states are handled gracefully
- Memory usage is bounded (no unbounded arrays)
- Follows existing project conventions (nonisolated store methods, @MainActor, etc.)

### 4. Functionality (weight: 30%)
- **Blocking**: Daily Report renders without crash
- **Blocking**: All 5 sections display real data when available
- **Blocking**: AI generation produces valid JSON and falls back gracefully
- **Blocking**: Copy-paste WeChat draft works
- **Blocking**: No regressions in 复盘 tab
- **Non-blocking**: Load time targets (< 3s cached, < 15s AI)
- **Non-blocking**: Stale data gracefully degrades

## Task-Specific Dimensions

### 5. Data Fidelity (weight: 20%, added to baseline)
- Highlights link back to real chat sources
- Todos show actual content from review_todos table
- Commitments show real deadline and status
- Reply debt reflects actual unread + unresponded state
- No fabricated or hallucinated data in non-AI sections

### 6. AI Quality (weight: 15%, added to baseline)
- Narrative references specific conversations, not generic summaries
- Tomorrow focus is grounded in real deadlines and pending items
- WeChat draft is copy-ready and professionally phrased
- JSON schema is validated before parsing
- Retry logic handles malformed responses

## Penalties
- Generic AI-looking dashboard layout: -15%
- Missing error state UI: -10%
- AI narrative is boilerplate (could apply to any user): -20%
- Data sources not linked (highlights without chat names): -10%
- Force unwraps or unsafe optional handling: -10% each
- Regression in 复盘 tab: automatic FAIL

## Verification Plan
1. Build project, check for compile errors
2. Run existing tests, verify no regressions
3. Inspect new UI code for SwiftUI correctness
4. Verify data model integrates with existing store methods
5. Check AI prompt and parsing logic for error handling
6. Manual code review for force unwraps and unsafe patterns
