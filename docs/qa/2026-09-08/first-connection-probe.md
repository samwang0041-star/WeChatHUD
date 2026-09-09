# 首次连接读取能力探针

日期：2026-09-08。范围是只读核查；未运行 scanner/wxkey，未提权、未终止微信、未修改签名、未读取或输出任何密钥内容。

## 结论

当前没有证据表明 WeChatHUD 能在正式微信上完成“普通用户点击一次即可首次读取”，同时不修改微信签名、不关闭 SIP、也不要求保存管理员密码。现有连接页可以发现/选择 `db_storage`、申请文件访问、验证已有 key JSON 并触发同步；它不生成首次读取材料。

## 证实的代码路径

- `Sources/WeChatHUD/Views/WeChatConnectionSetupView.swift:79-104, 333-392`：连接准备依赖 `WeChatReader.validateKeyFile`。在默认路径 `~/.wechat-cli/all_keys.json` 不存在或无效时，页面只进入“还不能直接连接”状态；`authorizeDirectory` 只选择资料目录并保存配置。
- `Sources/WeChatHUD/Data/WeChatReader.swift:105-145`：`databaseCandidates`/`autoDetectDBDir` 只扫描本地目录；`validateKeyFile` 只验证 JSON 非空，不提取 key。
- `/Users/yuriwong/wechatcli/repo/wechat_cli/keys/scanner_macos.py:119-153, 168-196`：首次材料来自外部 C 二进制扫描微信进程内存。遇到 `task_for_pid` 后调用 `_resign_wechat`；该函数在 `:70-116` 对 `/Applications/WeChat.app` 加入 `com.apple.security.get-task-allow` 后 ad-hoc 重签，并要求退出/重启微信后以 `sudo wechat-cli init` 重试。
- `/tmp/wechathud-wxkey-review-20260908/internal/machvm/machvm.go:82-94`：替代实现的进程附加错误明确要求“admin privileges plus ad-hoc-signed WeChat”。
- `/tmp/wechathud-wxkey-review-20260908/cmd/wxkey/main.go:1191-1228, 1654-1677`：shadow 路线复制并 ad-hoc 签名 WeChat，但会先 kill/停止现有微信；PBKDF fallback 也会停止现有进程并随后重开。
- `/tmp/wechathud-wxkey-review-20260908/cmd/wxkey/main.go:2283-2374`：bootstrap/setup 的免 SIP 路径读取或弹窗获取管理员密码，验证后写入 macOS Keychain，并通过 `sudo -S` 使用。`SECURITY.md:19-21` 也明确说明 SIP 保持开启不等于无需管理员凭据。

## 当前正式微信签名观察

对 `/Applications/WeChat.app` 仅执行了 `codesign -d --entitlements :-` 和签名元数据读取。entitlements 中未出现 `com.apple.security.get-task-allow`；签名仍是 Apple runtime 签名形态。这里只记录权限结论，不记录应用身份、团队标识或用户数据。

这只能证明当前 app 没有给 scanner 所需的调试 entitlement；它不证明任何未执行的提取路径一定失败，也不证明 TCC/Taskgated 在所有系统版本上的具体错误码。

## 最小可验证下一步

在决定产品方案前，做一个隔离、可回滚的权限实验：使用测试副本/测试账号，明确记录副本创建、进程生命周期、账号绑定和恢复步骤；只验证“系统管理的授权 + 已签名 helper”能否对目标微信取得所需 task 访问并读取一个 page-1 HMAC 已验证的 key。实验不得改写 `/Applications/WeChat.app`、关闭 SIP、保存管理员密码或接触生产聊天数据。若该实验未成功，首次连接只能继续把“已有 key 文件”作为前置条件，不能宣称已完成普通用户闭环。


## 当前权限下的实际进程访问检查

后续新增无内存读取的极小 Mach 探针：仅执行 `task_for_pid` 并立即释放成功取得的 port。参数限制 1...INT_MAX，自身正对照 `--self` 返回 kern_return=0、exit=0；经进程路径确认的正式微信返回 kern_return=5、exit=1。源码与编译自测由 Luna 完成，主代理复核源码并重复两项检查。完整结果见 `first-connection-process-access.json`；可复查源码见 `first-connection-process-access.c`。

微信原本未运行，通过原生应用入口打开后停留在“进入微信”页面；未点击登录、未扫描内存、未读取密钥、未提权、未改签名、未修改系统授权。这个结果证明当前未提权探针不能取得正式微信 task port，不能外推为所有授权 helper 均失败。它排除了将现有扫描器直接放到普通按钮后即可闭环的假设。下一实验仍需具体授权设计和隔离账号环境，不能在正式微信上自动执行旧扫描器的重签/提权回退。

### 更小权限的只读 task port

进一步核查 Apple 的 [XNU 实现](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_proc.c#L5757)，`task_read_for_pid` 为只读 task port，但仍经过 POSIX、MAC policy 与 taskgated 检查；该 main 分支不是当前机器内核版本的逐字对应证据。当前 SDK sys/syscall.h 提供 SYS_task_read_for_pid。

另建 `first-connection-read-port.c`，只请求/释放 port，不读取任何内存。主代理审核并验证：自身正对照 return=0 errno=0 exit=0；当前正式微信 return=-1 errno=1(EPERM) exit=1。该结果说明当前未提权调用者连只读 port 也无法取得，不能证明另一个获授权签名 helper 的结果。未调用更改权限或签名的回退。
