<p align="center">
  <img src="Resources/AppIcon.svg" width="128" height="128" alt="不漏事">
</p>

<h1 align="center">不漏事</h1>

<p align="center">
  <strong>安静地替你记住，需要你时把事情说清楚。</strong><br>
  macOS 上的微信聊天伴侣
</p>

<p align="center">
  <a href="https://github.com/samwang0041-star/WeChatHUD/releases/latest"><img src="https://img.shields.io/badge/下载-1.2.1-0B5960?style=for-the-badge" alt="下载 1.2.1"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-66D4B7?style=for-the-badge" alt="macOS 14+">
  <img src="https://img.shields.io/badge/芯片-Apple%20Silicon-074E55?style=for-the-badge" alt="Apple Silicon">
</p>

<p align="center">
  <a href="https://github.com/samwang0041-star/WeChatHUD/releases/latest/download/WeChatHUD-1.2.1-macOS14-arm64.zip">下载正式版安装包</a>
  ·
  <a href="docs/user-guide.md">使用指南</a>
  ·
  <a href="#从源码构建">从源码构建</a>
</p>

---

**不漏事**住在菜单栏和屏幕上方。它只看你选中的微信对话，把该回、该做、该记住的事整理到这台 Mac。

群里有人 @ 你、有人让你办事、你随口答应过一句——这些不该被下一屏消息冲掉。打开「今天」，先处理真正值得你看的那几条。

仓库名是 `WeChatHUD`，打开之后看到的名字是 **不漏事**。

## 它是做什么的

不漏事是微信的本机助手，不是另一个聊天软件。

| 它会做 | 它不会做 |
| --- | --- |
| 读取你已经登录的微信，整理关注的对话 | 替你登录微信，或上传账号 |
| 标出该回、该做、你答应过的事 | 默认替你发出任何消息 |
| 按需用你自己的 AI 写摘要和回复草稿 | 把聊天存到我们的服务器（没有云端账号） |
| 确认后，帮你跳到微信或送出草稿 | 修改微信里的聊天记录 |

适合每天消息很多、又必须记住几件要紧事的人。闲聊可以先收起来；真正要跟进的，留在「今天」。

## 每天怎么用

**今天**  
先看需要回复、需要你做、以及在等对方的事。点开一条就能看原文、摘要和下一步。普通更新可以稍后提醒，或标成已处理。

**待办 / 我答应的事**  
从聊天里记下谁来做、截止时间和原话。真正做完了再勾掉，不要只靠自动整理。

**草稿**  
在对话里写好回复后存下来。之后可以接着改、复制，或回到原对话。草稿不会自己发出去。点「发送」时会先让你看清发给谁、发什么。

**群里有人 @ 你**  
一句话说清发生了什么、为什么找你、接下来怎么办。不确定时，回到微信原文核对。

**头顶上的提醒**  
可以分别决定：群里 @ 你、重点联系人、普通更新要不要弹出。鼠标移上去就能继续看。

**自动回复（默认关闭）**  
忙的时候可以先让助手写好回复。打开后，写好的内容先出现在「待确认回复」。群聊不会自动发；转账、红包这类消息也不会自动回。开始时只选一两个人试。

<p align="center">
  <img src="docs/assets/readme/connect-wechat.png" width="480" alt="第一次打开：连接你的微信">
</p>

<p align="center"><em>第一次打开会引导你连接这台 Mac 上已登录的微信。</em></p>

## 下载与安装

1. 从 [Releases](https://github.com/samwang0041-star/WeChatHUD/releases/latest) 下载  
   [`WeChatHUD-1.2.1-macOS14-arm64.zip`](https://github.com/samwang0041-star/WeChatHUD/releases/latest/download/WeChatHUD-1.2.1-macOS14-arm64.zip)
2. 解压后，把 **WeChatHUD** 拖进「应用程序」
3. 打开应用。菜单栏会出现不漏事

需要：

- macOS 14 或更新版本
- Apple 芯片（arm64）
- 这台 Mac 已安装并登录微信

跳转到微信或送出草稿时，系统可能要求在「系统设置 → 隐私与安全性 → 辅助功能」里允许不漏事。按提示打开即可。

如果系统提示无法验证开发者，按住 Control 再点应用图标，选择「打开」。同一份 zip 附带 `.sha256` 校验文件。

## 第一次使用

大约 3 分钟。

1. **先打开并登录微信**，再回到不漏事，点「连接微信」。
2. 系统出现授权窗口时，直接点「允许读取」。不用自己找文件夹。
3. 有的 Mac 还需要一次「本机读取准备」，大约 1–2 分钟。微信可能会退出，重新打开并登录即可；聊天记录不会被改动。
4. 出现「微信已连接」和更新时间，这一步才算完成。
5. 选一个要关注的联系人或群。从一个人开始就够了。
6. 需要摘要和回复草稿时，再选一个 AI 服务并测试连接。没有 AI 也能看原文。

<p align="center">
  <img src="docs/assets/readme/setup-ai.png" width="480" alt="可选：设置 AI 并测试连接">
</p>

<p align="center"><em>AI 是可选项。测试连接只发送测试文本，不包含聊天记录。</em></p>

平时在「微信连接」查看状态。要换账号，用「更换微信账号」；不同账号的待办、草稿和关注名单分开保存。

## 数据怎么处理

- 微信聊天按只读方式在本机读取。助手整理出的事项、草稿和设置保存在这台 Mac（`~/.wechat-hud`）。
- 不漏事不替你登录微信，也不会把密钥或聊天上传到我们这边。
- 打开 AI 后，相关聊天片段会发给**你自己选择的服务**（DeepSeek、Kimi、智谱、本机 Codex 等），用来写摘要和草稿。请只用你信任的服务。
- API Key 和登录状态只留在你的 Mac 和对应官方工具里，不要写进截图或工单。

更细的说明见 [使用指南](docs/user-guide.md)。

## 从源码构建

需要 Xcode 命令行工具。在仓库目录：

```bash
make app && make run          # 编译并打开
make test                     # 运行测试
make package                  # 生成 zip 与 SHA-256
```

演示模式使用虚构资料，不读取、不操作真实微信：

```bash
make preview
open ".build/WeChatHUD Preview.app"
```

发行包是 Apple Silicon、面向 macOS 14。打包步骤、签名和公证见 [分发说明](docs/distribution.md)。

## 文档

- [使用指南](docs/user-guide.md) — 连接、日常使用、权限和排障
- [分发说明](docs/distribution.md) — 安装包、签名与公证
- [产品化说明](docs/2026-09-07-productization.md) — 范围与边界

## 版本

当前正式版是 **1.2.1**。应用内可以检查 GitHub Releases 上的更新。

源码与安装包都在这个仓库。欢迎先读使用指南，再决定要不要从源码自己编一份。
