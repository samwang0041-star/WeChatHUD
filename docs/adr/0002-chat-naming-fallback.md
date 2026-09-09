# ADR-0002: 会话名称解析与未命名群聊回退

## Status

Accepted

## Context

用户反馈：收件箱里出现了「43753159251@chatroom」这样的会话名，客户体验差。

排查结论（基于本机真实数据）：

- WeChat 的 `contact.db` 里，1180 个群聊中有 **357 个 `nick_name` 和 `remark` 都为空**。也就是说微信自己就没给这些群起名字。
- 代码里其实已经有「未命名群聊」兜底，但 **`displayName(for:)` 先查 `contactCache`，而缓存里存的正是那个兜底字符串**，因此后面基于成员推导的名字永远轮不到。
- 更早版本的代码直接把 `username` 当作显示名，于是 **历史数据里 `commitments`/`discussion_items`/`pending_asks` 等表存了 132 行原始 `…@chatroom` id**，而且 `commit_to` 字段另有 4 行。这些行不会因为修好解析逻辑而自动变好。
- 承诺详情里的「答应谁」直接显示 `commit_to`，模型在无法判断对象时会把这个群 id 原样写进去。

## Decision

1. **名称优先级**：用户自定义名称（`chat_aliases`）> 微信名（remark → nick_name）> 成员推导名（`群聊 · 赖豪、张沛…`）> 「未命名群聊」。任何情况下都不显示原始 `…@chatroom` id。
2. **成员推导**：从 `chat_room` + `chatroom_member` + `name2id` 关联出成员显示名，跳过自己、跳过仍是 wxid 的成员，最多列 3 人加「等」。实测把未命名群从 357 个降到 2 个（剩下两个群里只有用户自己，没有任何可读信息）。
3. **区分「微信有没有名字」与「显示什么」**：`ContactIdentityIndex` 额外保存 `weChatNameByUsername`。成员推导名读起来像名字，但对用户来说仍是兜底，UI 需要据此决定是否引导用户命名。
4. **用户可命名**：新增 `chat_aliases` 表，入口在会话详情标题栏（铅笔图标，仅当微信确实没名字时出现）和「关注的对话 → 编辑详情」。命名后通过 `propagateChatName` 回写所有缓存了旧名称的表，包括 `commit_to` 中恰好等于该会话名的值。
5. **历史数据修复**：扫描时调用 `repairStaleChatNames` / `repairStaleCommitTargets`，只处理「原始 id 或裸兜底字符串」的行，解析不出更好的名字就保持原样（绝不写空）。稳态下探测到没有待修行就直接跳过，不开写事务。

## Consequences

- **Positive**：会话名对用户可读；用户可自行命名并全站生效；历史脏数据自动收敛；`@chatroom` 不再出现在任何界面。
- **Negative**：成员推导名在成员变动后可能过期（只在下一次 `contact.db` 刷新时更新）；同名会话的推导名可能相近。两者都只是兜底，用户命名后即被覆盖。
- **注意**：`WeChatLauncher.openChat(named:)` 仍用显示名去微信搜索框匹配，因此改名后「在微信中打开」会搜不到该群。这是既有行为（本来依赖微信里的名字），本次不改；后续若要修，应改为按 `chatUsername` 定位会话。

## Verification

- 单元/集成测试：`ChatNamingTests`（16）、`ChatNamingRepairLiveTests`、`ChatNamingLiveCheckTests`、`ChatNamingLiveHintTests`、`ChatNamingMonitorLiveTests`。
- 真实数据只读校验：1182 个群中未命名 2 个；`43753159251@chatroom` → `群聊 · 上步雍勋、张沛、赖豪`。
- 真实数据修复校验：132 行原始 id + 4 行 `commit_to` 全部收敛，`hud.sqlite3` 中 `…@chatroom` 计数为 0。
- 真机 UI 走查：重命名 → 全站生效 → 清空 → 回退到成员推导名，均通过。
