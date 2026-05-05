# Self Supervision

## Gate Commands

Checkpoint:

```bash
HARNESS_SKILL_DIR=/Users/yuriwong/.codex/skills/agent-harness
HANDOFF_WORKSPACE=/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/daily-report-real-e2e-20260505
"$HARNESS_SKILL_DIR/scripts/harness-gate.sh" --workspace "$HANDOFF_WORKSPACE" --mode long-job --stage checkpoint
```

Final:

```bash
HARNESS_SKILL_DIR=/Users/yuriwong/.codex/skills/agent-harness
HANDOFF_WORKSPACE=/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/daily-report-real-e2e-20260505
"$HARNESS_SKILL_DIR/scripts/harness-gate.sh" --workspace "$HANDOFF_WORKSPACE" --mode long-job --stage final
```

## Monitor

Start from this active agent session after request/spec/rubric/contract exist:

```bash
"/Users/yuriwong/.codex/skills/agent-harness/scripts/harness-monitor.sh" \
  --workspace "/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/daily-report-real-e2e-20260505" \
  --mode long-job \
  --stage final \
  --interval 30 \
  --idle-timeout 600 \
  --cwd "/Users/yuriwong/wechatcli/WeChatHUD" \
  --request-file "/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/daily-report-real-e2e-20260505/00-request.md" \
  > "/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/daily-report-real-e2e-20260505/monitor-supervisor.log" 2>&1 &
echo $! > "/Users/yuriwong/wechatcli/WeChatHUD/.agent-harness/daily-report-real-e2e-20260505/monitor.pid"
```

## Timeouts

Idle timeout: 600 seconds. Maximum duration: current interactive task budget; stop on repeated substantive failure.

## Failure Rule

If the gate fails, continue the harness cycle instead of replying final.

## Logs

- Monitor log: `monitor-supervisor.log`
- Monitor pid: `monitor.pid`
- Gate output: `checkpoint-gate.log`, `final-gate.log`
- Resume prompt if stalled: `runner-next-prompt.md`

## Smallest Safe Resume Instruction

Resume from `45-checkpoint.md`, inspect current diff and test logs, then either fix blocking evaluator findings or run the final gate if `Decision: PASS` and `50-final-summary.md` are present.
