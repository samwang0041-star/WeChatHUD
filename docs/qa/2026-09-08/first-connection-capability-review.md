# 首次连接能力复核

2026-09-08，当前工作树只读复核；未运行密钥提取、提权或更改微信签名。

WeChatHUD 的连接页只选择账号资料目录、验证现有读取材料、保存配置并重启/同步。它没有首次生成读取材料的实现。文件授权不是完成首次连接的充分条件。

本地 CLI 的 `wechat_cli/commands/init.py` 调用 `wechat_cli/keys/scanner_macos.py` 的扫描程序。后者遇到 task_for_pid 失败，会调用 `_resign_wechat()`，给微信加入 get-task-allow 并尝试 ad-hoc 重新签名；随后提示重启微信和再次初始化。因此不能未经明确设计与授权直接作为普通用户的一键连接实现。

本轮另修正 WeChatConnectionSetupView.persistRoot：先成功持久化候选配置，再更新界面状态；删除重复配置变更通知。ConnectionSetupPolicyTests 10项通过。该验证不代表新Mac连接或读取权限已通过。

发布门槛仍缺：无需用户理解数据库/密钥/命令行的首次读取方案、其权限与失败恢复，以及全新Mac实际验收。当前不得标记目标完成。


## Updated upstream investigation

Reviewed `r266-tech/wxkey` at commit `01e96fa58ce3ff061dce83e4c36f62104ebc6b16` from a read-only clone in `/tmp/wechathud-wxkey-review-20260908`. No bootstrap, scanner, downloaded executable, sudo operation, Keychain access, or WeChat modification was run.

The source offers a different route: a managed WeChat copy rather than modifying the installed original. However, `prepareShadowWeChatCopy` terminates WeChat by process name and ad-hoc signs the copy. Its bootstrap stores the administrator password in Keychain and later feeds it into sudo. Therefore “SIP stays enabled” alone does not establish a suitable consumer integration. The implementation changes which WeChat executable runs and must be evaluated for account continuity, unsaved input, and cleanup; compatibility on this Mac has not been established.

Code evidence: [copy preparation](https://github.com/r266-tech/wxkey/blob/01e96fa58ce3ff061dce83e4c36f62104ebc6b16/cmd/wxkey/main.go#L1191-L1229), [credential storage](https://github.com/r266-tech/wxkey/blob/01e96fa58ce3ff061dce83e4c36f62104ebc6b16/cmd/wxkey/main.go#L2321-L2337).

Design direction to investigate, not an implemented solution: an app-owned narrowly scoped helper using system-managed authorization, without retaining an administrator password. Apple documents [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) for registering and observing helper executables. This API does not establish permission to attach to the official WeChat process. A signed isolated proof must establish that separately before any onboarding claims or integration. The next acceptance experiment needs explicit scope for the temporary WeChat copy and restoration, deterministic account binding, and verified reads against the selected account.
