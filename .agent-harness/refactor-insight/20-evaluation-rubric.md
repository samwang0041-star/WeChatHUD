# Evaluation Rubric

## Dimensions

### Craft (weight: 35%)
- No duplicated AI call / parse / audit / retry logic across analyzers
- Consistent naming: all insight-related services use clear, non-overlapping names
- File organization: related files grouped under Services/Insight/
- Actor isolation boundaries are correct and compile without `@preconcurrency` hacks
- No force-unwraps or unsafe optional handling introduced

### Functionality (weight: 35%)
- `swift build` produces zero errors
- ChatInsightView loads stats and renders without crash
- Single-chat AI analysis produces ChatInsightResult correctly
- Global briefing generation works end-to-end
- Radar findings are built correctly from insights + overview
- ChatSummary (group/private), ContextAnalysis, RecallAnalysis all function

### Design Quality (weight: 20%)
- Clear separation: pipeline does AI, service does domain logic, coordinator does scheduling
- InsightStore is a pure state container, not a data loader
- Protocol-based or shared-infrastructure pattern for analyzers
- Minimal surface area: new types and files are justified, not speculative abstraction

### Maintainability (weight: 10%)
- Adding a new AI analyzer in the future requires only domain-specific code
- Audit logging happens automatically, not as copy-paste in each service
- Retry logic is centralized, not scattered

## Blocking Criteria
- Build failure (any compiler error)
- Runtime crash in insight flow
- Lost functionality: any existing feature no longer works
- Race condition or actor isolation violation introduced

## Calibration Examples
- Excellent: A single `AIAnalysisPipeline` actor handles all AI calls; each service only defines prompt, parser, and domain model; audit is automatic
- Acceptable: Pipeline extracts common patterns but some services still have slight duplication; build passes; all features work
- Failing: Build breaks; services still have duplicated call/retry/audit code; insight flow crashes or loses data

## Verification Plan
1. `swift build` — must be zero errors
2. Inspect diff — check for duplicated patterns remaining
3. Review file structure — Services/Insight/ should contain grouped files
4. Code review — actor boundaries, protocol usage, naming clarity
5. If possible: run app and verify ChatInsightView loads
