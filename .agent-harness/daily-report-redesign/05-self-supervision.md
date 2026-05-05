# Self-Supervision Record

## Gate Commands

Checkpoint gate:
```bash
"/Users/yuriwong/.claude/skills/agent-harness/scripts/harness-gate.sh" --workspace "/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/daily-report-redesign" --mode long-job --stage checkpoint
```

Final gate:
```bash
"/Users/yuriwong/.claude/skills/agent-harness/scripts/harness-gate.sh" --workspace "/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/daily-report-redesign" --mode long-job --stage final
```

## Monitor Decision
Monitor not started — this is a design-phase task (no code implementation), single-pass with one iteration cycle is sufficient. Self-supervision is done manually via gate checks.

## Idle Timeout / Max Duration
- Idle timeout: N/A (design task, no long-running processes)
- Max duration: N/A

## Failure Rule
If gate fails, continue the harness cycle:
- Write missing artifacts
- Perform missing verification
- Update 40-evaluation-report.md
- Write or refresh 45-checkpoint.md
- Do NOT reply final until gate passes

## Log/Prompt Paths
- Handoff workspace: `/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/daily-report-redesign/`
- Next prompt file: N/A (no runner used)
- Gate output: stdout

## Resume Instruction
If runtime stops, resume from latest artifact:
1. Read 00-request.md for context
2. Read 10-product-spec.md for product spec
3. Read 35-context-transition.md for latest corrections
4. Continue from where left off
