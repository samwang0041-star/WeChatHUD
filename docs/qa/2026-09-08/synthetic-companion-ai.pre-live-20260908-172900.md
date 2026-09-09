# Synthetic companion AI acceptance — 2026-09-08

This evidence came from fictional project-chat inputs and a temporary HUDStore. It does not include the device API key, endpoint, prompts, real chat rows, or real contact names. A passing test means the configured provider returned parseable results that satisfied the assertions below; it does not prove delivery or autonomous sending.

- Generated at: `2026-09-08T06:23:49Z`
- Provider: `deepseek`
- Configured model: `deepseek-v4-flash`
- Opt-in: `WCHUD_LIVE_COMPANION_AI=1`

## AIClassifier — synthetic group @ context

Input: fictional `@我` request to send a risk list before 17:00.

status=returned, isAsk=true, type=send_file, confidence=0.95, deadlinePresent=true, summary=发送风险清单到项目群

## AIGroupCatchup — synthetic group context summary

status=returned, needsUserAction=true, highlightCount=3, skipSafe=false, headline=客户今晚要看风险清单，需你17点前发群, actionSummary=请在今天17:00前把风险清单发到群里

## AIChatInsight — synthetic chat insight

status=returned, mentionsMe=1, actionItemCount=1, actionOwners=["我"], needsMyAttention=true, headline=客户今晚要看风险清单，我承诺今天17:00前在群里发布最终版, insight=今日消息聚焦于风险清单的交付，周宁补充的接口异常日志可能为风险清单提供数据支撑，但未明确关联。, suggestion=建议我按时在17:00前发布风险清单，并确保包含接口异常日志的相关内容。, commitments=["今天17:00前发布最终风险清单"]

## AIReplySuggester — synthetic reply candidates

status=returned, count=1, tones=["formal"], safeToSend=[true], texts=["我确认下最终版本，尽量17:00前发"]

## AutoReplyGenerator — synthetic guarded decision

status=returned, action=send, confidence=0.95, risk=low, reply=收到，17:00前发群里, reasoning=对方要求确认收到，回复确认即可，符合用户简洁风格，无风险。

## CommitmentTracker — synthetic self-promise

status=returned, isCommitment=true, confidence=0.95, content=今天17:00前把最终风险清单发到群里, commitTo=林晓, deadlineLabel=今天17:00前, kind=deliverable, persisted=true

## CommitmentTracker — negative other-person action

status=returned, isCommitment=false, content=

## Prior live semantic finding

The first live run exposed a real directionality defect: the model returned `并告知林晓` for the synthetic phrase `林晓收到后告诉我`, reversing who should report to whom. The final run keeps that failure visible and asserts that the corrected prompt no longer returns that inverted action.

## Temporary-store AI audit

auditCount=7, auditModels=["deepseek-v4-flash"], auditStatuses=["ok", "ok", "ok", "ok", "ok", "ok", "ok"]

## Boundary

No message was sent to WeChat. No real WeChat database or production HUD SQLite file was opened. The test uses bounded service timeouts and each service's existing single strict-JSON retry.