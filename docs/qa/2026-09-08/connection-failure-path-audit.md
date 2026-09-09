# 首次连接失败路径审计（2026-09-08）

范围：只读检查 `WeChatConnectionSetupView`、`ConnectionSetupPolicy`、`ChatMonitor`、`WeChatReader` 和现有 readiness 测试。本文没有执行系统授权、没有切换真实账号，也没有修改产品代码。结论针对“第一次连接失败后，普通用户能否知道下一步并完成连接”。

## 结论

当前界面可以避免把一个磁盘目录直接猜成当前账号，但失败后的恢复路径仍然容易卡住。最严重的问题是：缺少或不匹配的密钥没有可执行的下一步；已保存的旧账号目录会遮住“当前微信账号已变更”；“允许读取”只证明目录和 `session.db` 可见，不能证明聊天真的能读，文案和两步进度条会让用户误以为已经接近完成。

## 发现

### P0：缺少密钥时只给“重新检查”，用户没有完成路径

复现：微信已运行，用户选中了含 `session.db` 的目录，但默认密钥文件不存在、不可读或 JSON 无法使用。点击“连接微信”后，`preparationReady` 为假，流程只把 `preparationUnavailable` 设为真并返回（[WeChatConnectionSetupView.swift:327-334](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatConnectionSetupView.swift:327)）。标题解释为“这台 Mac 还不能直接连接”，主按钮变成“重新检查”（[WeChatConnectionSetupView.swift:125-132](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatConnectionSetupView.swift:125)、[WeChatConnectionSetupView.swift:151-161](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatConnectionSetupView.swift:151)），再次点击仍走同一检查；该视图没有“选择密钥文件”或打开设置的入口。选择目录后的 `select` 分支也只会再次标记 unavailable（[WeChatConnectionSetupView.swift:381-390](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatConnectionSetupView.swift:381)）。内容有效但不匹配当前账号时，文件可读检查会通过，随后会落入同步失败路径（见下方 P1）。

普通用户看到的是“重新检查”，但缺少的东西不会因重试而出现。这是确定性的死循环，且 `OnboardingReadiness` 只把它列为“配置解密密钥”，没有把向导按钮接到该动作（[OnboardingReadiness.swift:13-20](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/OnboardingReadiness.swift:13)）。设置页虽有“选择 JSON…”入口（[SyncSettingsView.swift:280-298](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift:280)），但连接失败卡片没有告诉用户去那里。此次审计后已修复其中的“状态粘住”问题：`refresh()` 和重新选择目录会根据实时 `preparationReady` 清除旧的 unavailable 标记；缺少材料时仍会停留在同一无出口状态，P0 的产品路径问题仍然存在。

建议：把该状态改成清楚的单一下一步，例如“需要准备聊天读取文件”，正文只解释“请先选择与你的微信账号匹配的文件”，主按钮直接打开选择入口；选择成功后重新检查。若项目必须由配套工具生成文件，也应给出明确的“打开准备工具/查看步骤”动作，而不是让用户反复点“重新检查”。

### P1：同步失败的真实原因被统一显示成“确认微信已登录”

`syncFailed` 只识别 `.error`（[WeChatConnectionSetupView.swift:119-123](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift:119)），正文固定为“请确认微信已经登录，再试一次”（[WeChatConnectionSetupView.swift:136-148](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift:136)）。监控器实际还会产生 `accountSwitched`（已配置目录消失）和 `waitingForWeChat` 等状态（[ChatMonitor.swift:1105-1129](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Services/ChatMonitor.swift:1105)），扫描失败也只写入通用字符串 `scan failed`（[ChatMonitor.swift:1166-1176](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Services/ChatMonitor.swift:1166)）。因此“密钥无效、目录不再对应当前账号、数据库读失败”都会落到“再登录微信”的建议，用户无法采取正确动作。

建议：把连接结果拆成用户能执行的三类：微信未运行、目录需要重新选择、读取材料缺失/不匹配；保留底层错误用于诊断，但卡片必须给出对应按钮。至少不要把 `accountSwitched` 当成普通重试。

### P1：账号已切换时没有“更换微信账号”入口，旧目录可能持续占据配置

“更换微信账号”只在 `connected` 为真时显示（[WeChatConnectionSetupView.swift:215-223](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift:215)）。而 `connected` 要求最近一次同步成功且监控器状态为 `.ok`（[WeChatConnectionSetupView.swift:108-112](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift:108)）。如果用户退出账号、换号或旧目录消失，监控器进入 `.accountSwitched`，界面既不是 `connected`，也不是 `syncFailed`，标题退回“连接你的微信”；配置根仍是旧路径时，主按钮会重复使用显式旧配置（策略规定显式目录优先，[ConnectionSetupPolicy.swift:21-38](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Data/ConnectionSetupPolicy.swift:21)）。

此时用户看不到“更换微信账号”，只能点普通“连接微信”，流程再尝试旧配置，随后可能打开授权目录选择器（[WeChatConnectionSetupView.swift:314-329](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift:314)）。这既不说明发生了换号，也容易让用户以为是在重复授权同一个账号。

建议：当监控器报告 `accountSwitched`、已配置目录消失，或读取结果与当前运行微信不一致时，始终显示“重新选择微信账号”主动作；选择新目录后明确显示“已保存，重启后检查”。不要要求用户先达到 `connected` 才能换号。

### P1：两步进度把“允许读取”当成有效连接前置，掩盖了真正的验证失败

进度条只展示“允许读取 → 检查连接”，第一步由目录可读且存在 `session.db` 判定完成（[WeChatConnectionSetupView.swift:85-91](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift:85)、[WeChatConnectionSetupView.swift:180-185](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatConnectionSetupView.swift:180)）。但 `WeChatReader.accessMaterialState` 的 `.available` 也只表示密钥文件存在且可读，源码明确说明“成功数据库读取才证明密钥匹配”（[WeChatReader.swift:145-155](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Data/WeChatReader.swift:145)）。设置页同样写明“文件可读不代表内容有效或匹配当前账号”（[SyncSettingsView.swift:311-316](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/Settings/SyncSettingsView.swift:311)）。

这会产生明显误导：用户已经看到“允许读取”打勾，但下一步失败仍只给通用重试。建议把第一步命名为“找到微信资料”，把“验证能否读取聊天”作为唯一完成条件；不要在密钥尚未验证时呈现接近完成的绿色进度。

### P2：技术词和泛化授权文案增加了首次失败的理解成本

系统选择器标题为“允许聊天伴侣读取微信”，但实际选择的是一个目录（[WeChatConnectionSetupView.swift:349-359](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift:349)）；失败文案包含“首次读取准备”“解密密钥”等普通用户未必理解的词（[WeChatConnectionSetupView.swift:141-148](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift:141)、[OnboardingReadiness.swift:15-17](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/OnboardingReadiness.swift:15)）。选择器允许用户在任意目录中导航，若找不到 `session.db`，只提示“还没有找到聊天资料”，没有指出应该回到微信账号目录（[WeChatConnectionSetupView.swift:360-371](/Users/yuriwong/wechatcli/WeChatHUD/Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift:360)）。

建议首屏只保留三种普通话术：“打开并登录微信”“选择这个微信账号”“正在验证能否读取聊天”。把“目录、密钥、解密”移到“查看详情”或诊断入口，并在选择器内给出可识别的账号名/目录示例。

## 建议验收场景

1. 新安装、微信未登录：点击一次后能看到“打开并登录微信”，登录回来继续，不进入空转重试。
2. 目录可见但没有读取材料：主按钮能直接进入准备/选择材料动作；完成后能自动再次验证。
3. 材料文件可读但不匹配：显示“读取失败，请选择匹配这个微信账号的材料”，不能显示已连接。
4. 微信从账号 A 换到账号 B：无论当前是否曾成功连接，都能看到“重新选择微信账号”，选择 B 后状态、重启提示和最终成功同步一致。
5. 旧目录消失或微信未运行：分别给出“重新选择账号”和“打开微信”，而不是共享“重试连接”。


## Follow-up: missing-account recovery implemented

The connection card now presents 选择微信账号 when the monitor reports its account directory unavailable and the currently selected root still matches that reader. The action opens account selection directly once WeChat is running. A newly saved root does not inherit the old reader status; it can proceed to the existing restart/check flow. Existing selections can also be changed after sync errors. Account-selection controls are disabled while a connection or sync is busy.

Validation: 14 ConnectionSetupPolicyTests passed, including three regressions for unavailable current root, stale status after a new selection, and ordinary errors. Root independently ran swift build successfully and reviewed the action dispatch. No real account switch was performed, so native missing-directory recovery remains unverified. This patch does not detect live account divergence while the original directory still exists, and it does not supply initial reading material.
