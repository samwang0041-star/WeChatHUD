<p align="center">
  <img src="Resources/AppIcon.svg" width="120" height="120" alt="WeChatHUD">
</p>

<h1 align="center">WeChatHUD</h1>

<p align="center">
  <strong>住在 Mac 刘海里的微信助手。</strong><br>
  你只选要关注的对话，它替你盯住：该回的、该做的、你答应过的。<br>
  平时安静地贴着刘海，有事才探出头来——不打断你，也不替你乱说话。
</p>

<p align="center">
  <a href="https://github.com/samwang0041-star/WeChatHUD/releases/latest"><img src="https://img.shields.io/badge/下载-1.5.7-0B5960?style=for-the-badge" alt="下载 1.5.7"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-66D4B7?style=for-the-badge" alt="macOS 14+">
  <img src="https://img.shields.io/badge/芯片-Apple%20Silicon-074E55?style=for-the-badge" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/签名-Developer%20ID%20已公证-6E56CF?style=for-the-badge" alt="已签名并公证">
  <a href="LICENSE"><img src="https://img.shields.io/badge/许可证-MIT-3DA639?style=for-the-badge" alt="MIT"></a>
</p>

<p align="center">
  <a href="https://github.com/samwang0041-star/WeChatHUD/releases/latest/download/WeChatHUD-1.5.7-macOS14-arm64.zip"><strong>下载安装包</strong></a>
  ·
  <a href="docs/user-guide.md">使用指南</a>
  ·
  <a href="#三分钟上手">三分钟上手</a>
  ·
  <a href="#它到底能做什么">它能做什么</a>
  ·
  <a href="#从源码构建">自己编译</a>
</p>

<br>

<p align="center">
  <img src="docs/assets/productization-2026-09-07/notification.png" width="640" alt="消息到达时，刘海下方展开一张可以直接处理的通知">
</p>

<p align="center"><em>
  消息到达时，刘海下展开一张能直接处理的通知：谁找你、什么事、什么情况、一键去微信——不用切窗口。
</em></p>

---

## 为什么做这个

微信里没有"待办"。

它是一条永不停歇的时间线：群在刷屏，人在找你，你昨天答应"明天发你"的那件事，沉在几百条消息底下，再也想不起来。要回的人、要做的事、你在等对方的回复——全散落在几十个对话里，靠脑子记，靠手动翻。漏掉一条要紧的，代价往往不是"少看一句话"，而是一次失约、一个延误、一段关系的凉掉。

市面上的做法要么让你把账号交给云端机器人，要么粗暴地自动回复——前者你不敢用，后者你不想用。**聊天软件最该被自动化的是"整理"，最不该被自动化的是"替你开口"。**

所以我们换了个思路，做了 WeChatHUD：

- 它不抢你的屏幕，**住在刘海里**——平时是一条安静的小胶囊，只有真正需要你时才展开。
- 它不替你做决定，**只把聊天变成一眼能处理的工作线索**：谁、什么事、第几分钟，点开就是摘要、原文和下一步建议。
- 它不碰云端，**全程只在你这台 Mac 上**读取你选中的对话；源库只读，绝不改动你的微信。
- 它不擅自发言，**没有你的确认，一个字都发不出去**；自动托管默认关闭，开了也只进"待确认"队列。

一句话：**把"我该回什么、我答应过什么、谁在等我"从记忆力负担里解放出来，但把"说不说、怎么说"的最终决定权，牢牢留在你手上。**

---

## 它到底能做什么

<p align="center">
  <img src="docs/assets/productization-2026-09-07/workspace.png" width="760" alt="原生工作台：今天视图">
</p>

<table>
  <tr>
    <td width="50%">

**📥 今天**

该回的消息、要做的事、在等对方的事，分列三张卡。数量不对就是有人没处理完——扫一眼就知道今天还压着什么。

**🤝 我的承诺**

"我明天发你"会被自动记下来：谁、什么事、截止时间、原话出处。做完了再亲手勾掉，不靠 AI 替你下"已完成"的结论。

    </td>
    <td width="50%">

**📣 群里 @ 你**

"看看什么事"一句话讲清：发生了什么、为什么找你、下一步怎么办。拿不准就回原文逐条核对，不被二手摘要带偏。

**✍️ 回复草稿**

AI 起草，你来改。存着、继续写、复制、或确认后送出——每一步都先让你看清"发给谁、发什么"，再决定。

    </td>
  </tr>
  <tr>
    <td width="50%">

**🔍 聊天洞察**

文字背后看不到的东西：情绪暗流、态度信号、关系变化、被忽略的信息。帮你 1 分钟看到一个对话的全貌。

**📈 关系雷达**

跨天跨周的趋势：谁的态度变了、谁沉默了几天、哪段关系在升温或降温。纯本机计算，低打扰，不自动发消息。

    </td>
    <td width="50%">

**🗒️ 每日简报**

今天处理了什么、还压着什么事，一页读完，可导出 Markdown 存档。

**⏱️ 按时间复盘**

选一段对话、一段时间，回看当时的决定和话题走向——"没回的"还能按今天 / 近 3 天 / 近 7 天 / 自选筛出来。

    </td>
  </tr>
  <tr>
    <td width="50%">

**🤖 自动托管（默认关闭）**

开了也先进"待确认"队列。群聊一律不自动发（@ 提醒也只出草稿）；转账、红包、验证码强制人工；每会话有发送上限。护栏在真实发送链路上执行。

**👥 多账号隔离**

换微信账号，待办、草稿、关注名单各自独立保存，互不串。

    </td>
    <td width="50%">

**🔔 主动提醒**

VIP 超时未回、承诺到期、连续消息、P0 待回——四条规则引擎在你需要时轻推一下，其余时间保持安静。

**🧠 越用越懂你**

学习你的写作风格，让回复建议更像你会说的话；你的反馈会持续打磨建议质量。

    </td>
  </tr>
</table>

---

## 三条不会动摇的底线

<table>
<tr><td width="33%" align="center">

**🔒 本机，不上云**

没有云端账号，也没有我们的服务器。聊天记录只在本机读取，整理结果存在你自己的 `~/.wechat-hud`。

</td><td width="33%" align="center">

**👁️ 只读，不改动**

源微信数据库全程只读。它看你的聊天，但永远不会动你的聊天。

</td><td width="33%" align="center">

**✋ 不确认，不发送**

任何一条要发出去的消息，都先让你看清收件人和内容。自动托管默认关闭，且群聊与金融类消息强制人工。

</td></tr>
</table>

---

## 三分钟上手

1. **下载** [`WeChatHUD-1.5.7-macOS14-arm64.zip`](https://github.com/samwang0041-star/WeChatHUD/releases/latest/download/WeChatHUD-1.5.7-macOS14-arm64.zip)，解压拖进「应用程序」——已签名并公证，双击即开。
2. **先登录微信**，再点「连接微信」。系统授权窗口点「允许读取」即可，不用自己找文件夹。
3. **选一个要关注的人或群**——从一个开始就够了。

<table>
  <tr>
    <td align="center" width="50%"><img src="docs/assets/readme/connect-wechat.png" width="400" alt="第 1 步：连接你的微信"><br><sub>连接本机已登录的微信</sub></td>
    <td align="center" width="50%"><img src="docs/assets/readme/setup-ai.png" width="400" alt="第 2 步：可选的 AI 服务"><br><sub>AI 是可选项，测试连接只发测试文本</sub></td>
  </tr>
</table>

> 需要 macOS 14+、Apple 芯片、这台 Mac 已登录微信。跳转微信或送草稿时，系统可能要求一次「辅助功能」授权，按提示打开即可。

## 你的数据，留在你的 Mac 上

| 问题 | 答案 |
| --- | --- |
| 聊天记录存哪？ | 只在本机读取微信数据库；整理结果保存在 `~/.wechat-hud` |
| 会上传到你们服务器吗？ | 不会——没有云端账号，也没有我们的服务器 |
| AI 用到什么数据？ | 打开 AI 后，相关片段发给你<b>自选</b>的服务（DeepSeek、Kimi、智谱、本机 Codex 等） |
| 它会自动发消息吗？ | 不会。发送前一定让你确认收件人和内容；托管默认关闭 |
| 会改我的微信吗？ | 不会。源库只读，聊天记录不被改动 |

更细的边界见 [使用指南](docs/user-guide.md) 与 [分发说明](docs/distribution.md)。

## 从源码构建

需要 Xcode 命令行工具（SwiftPM 直接构建，无 Xcode 工程）：

```bash
make app && make run          # 编译并打开
make test                     # 跑全部测试
make package                  # 签名打包 zip + SHA-256
```

想先逛逛界面？演示模式用虚构资料，不碰真实微信：

```bash
make preview
open ".build/WeChatHUD Preview.app"
```

## 文档

- [使用指南](docs/user-guide.md) — 连接、日常使用、权限、排障
- [分发说明](docs/distribution.md) — 签名、公证、打包流程
- [进化日志](docs/evolution-log.md) — 每个版本改了什么
- [产品化说明](docs/2026-09-07-productization.md) — 设计取舍与验收边界

## 许可证

[MIT](LICENSE) — 可以自由使用、修改、分发，包括商业用途，保留版权与许可声明即可。

随包分发的第三方组件只有 zstd（BSD-3-Clause），其许可证与来源说明在
`Contents/Resources/THIRD_PARTY_LICENSES/`。项目在设计阶段只读参考过若干公开仓库
（含 AGPL/GPL 项目），未复制其代码，详见 [参考边界](docs/2026-09-07-reader-reference-review.md)。

---

<p align="center">
  <sub>当前正式版 <strong>1.5.7</strong> · 源码与安装包同仓 · 应用内可检查更新</sub><br>
  <sub>用之前建议先读一遍 <a href="docs/user-guide.md">使用指南</a></sub>
</p>
