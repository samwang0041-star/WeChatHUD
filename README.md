<p align="center">
  <img src="Resources/AppIcon.svg" width="128" height="128" alt="WeChatHUD">
</p>

<h1 align="center">WeChatHUD</h1>

<p align="center">
  macOS 吸顶浮窗助手：从你选的微信对话里，整理待回、待办、承诺和回复草稿。<br>
  本机运行，AI 可选，默认不自动发送。
</p>

<p align="center">
  <a href="https://github.com/samwang0041-star/WeChatHUD/releases/latest"><img src="https://img.shields.io/badge/下载-1.2.15-0B5960?style=for-the-badge" alt="下载 1.2.15"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-66D4B7?style=for-the-badge" alt="macOS 14+">
  <img src="https://img.shields.io/badge/芯片-Apple%20Silicon-074E55?style=for-the-badge" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/签名-Developer%20ID%20已公证-6E56CF?style=for-the-badge" alt="已签名并公证">
</p>

<p align="center">
  <a href="https://github.com/samwang0041-star/WeChatHUD/releases/latest/download/WeChatHUD-1.2.15-macOS14-arm64.zip">下载正式版安装包</a>
  ·
  <a href="docs/user-guide.md">使用指南</a>
  ·
  <a href="#从源码构建">从源码构建</a>
</p>

---

## 它是什么

WeChatHUD 住在屏幕顶端的浮窗里。它只读取你选中的微信对话，在这台 Mac 上整理出该回的消息、该办的事、你答应过的事和待发的草稿。

它不是另一个聊天软件，也不是云端服务。

| 它会做 | 它不会做 |
| --- | --- |
| 读取这台 Mac 上已登录的微信 | 替你登录微信，或上传你的账号 |
| 标出该回、该做、你答应过的事 | 默认替你发出任何消息 |
| 用你自选的 AI 写摘要和回复草稿 | 把聊天存到我们的服务器（没有云端账号） |
| 确认后，帮你跳到微信或送出草稿 | 修改微信里的聊天记录 |

适合每天消息很多、又必须记住几件要紧事的人。闲聊先收起来；真正要跟进的，留在「今天」。

## 每天怎么用

**今天** — 先看需要回复、需要你做、在等对方的事。点开一条就能看原文、摘要和下一步。普通更新可以稍后提醒或标成已处理。

**待办与承诺** — 从聊天里记下谁来做、截止时间和原话。做完了再勾掉，不靠自动整理下结论。

**回复草稿** — 写好先存着，之后接着改、复制或回到原对话。草稿不会自己发出去；点「发送」前会让你看清发给谁、发什么。

**群里有人 @ 你** — 「看看什么事」一句话说清发生了什么、为什么找你、下一步怎么办。不确定时回到微信原文核对。

**浮窗提醒** — 群里 @ 你、重点联系人、普通更新分别可开关；鼠标移上去继续看，平时不打扰。

**自动托管（默认关闭）** — 打开后，写好的回复先进「待确认」。群聊不自动发；转账、红包、小程序、验证码这类内容强制人工确认；每个会话有发送上限。建议先选一两个人试用。

## 下载与安装

1. 从 [Releases](https://github.com/samwang0041-star/WeChatHUD/releases/latest) 下载  
   [`WeChatHUD-1.2.15-macOS14-arm64.zip`](https://github.com/samwang0041-star/WeChatHUD/releases/latest/download/WeChatHUD-1.2.15-macOS14-arm64.zip)
2. 解压后把 **WeChatHUD** 拖进「应用程序」，打开。菜单栏会出现 WeChatHUD。

需要 macOS 14+、Apple 芯片，且这台 Mac 已安装并登录微信。

正式版已用 Developer ID 签名并通过 Apple 公证，正常情况下双击即可打开。同一份 zip 附带 `.sha256` 校验文件，可用 `shasum -a 256 -c` 核对。

<p align="center">
  <img src="docs/assets/readme/connect-wechat.png" width="480" alt="第一次打开：连接你的微信">
</p>

## 第一次使用

大约 3 分钟：

1. 先打开并登录微信，回到 WeChatHUD 点「连接微信」；系统授权窗口里点「允许读取」。
2. 部分 Mac 需要一次「本机读取准备」（约 1–2 分钟），期间微信可能退出，重新登录即可，聊天记录不会被改动。
3. 出现「微信已连接」和更新时间，连接完成。
4. 选一个要关注的联系人或群——从一个人开始就够了。
5. 需要摘要和回复草稿时，再选一个 AI 服务并测试连接。没有 AI 也能看原文。

跳转到微信或送出草稿时，系统可能要求在「系统设置 → 隐私与安全性 → 辅助功能」里允许 WeChatHUD。

<p align="center">
  <img src="docs/assets/readme/setup-ai.png" width="480" alt="可选：设置 AI 并测试连接">
</p>

## 数据怎么处理

- 微信聊天按**只读**方式在本机读取和解密；整理出的事项、草稿和设置保存在这台 Mac（`~/.wechat-hud`）。
- 打开 AI 后，相关聊天片段会发给**你自己选择的服务**（DeepSeek、Kimi、智谱、本机 Codex 等），用于写摘要和草稿。请只用你信任的服务。
- API Key、解密密钥、OAuth 登录状态只留在你的 Mac 和对应官方工具里，不会进入截图、日志或发行包。

更细的边界说明见 [使用指南](docs/user-guide.md)。

## 从源码构建

需要 Xcode 命令行工具：

```bash
make app && make run          # 编译并打开
make test                     # 运行测试
make package                  # 生成签名 zip 与 SHA-256
```

演示模式使用虚构资料，不读取、不操作真实微信：

```bash
make preview
open ".build/WeChatHUD Preview.app"
```

签名与公证流程见 [分发说明](docs/distribution.md)。

## 文档

- [使用指南](docs/user-guide.md) — 连接、日常使用、权限和排障
- [分发说明](docs/distribution.md) — 安装包、签名与公证
- [产品化说明](docs/2026-09-07-productization.md) — 范围与边界
- [进化日志](docs/evolution-log.md) — 版本演进记录

## 版本

当前正式版是 **1.2.15**。应用内可以检查 GitHub Releases 上的更新。

源码与安装包都在这个仓库。欢迎先读使用指南，再决定要不要从源码自己编一份。
