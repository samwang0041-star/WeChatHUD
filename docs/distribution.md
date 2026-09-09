# WeChatHUD 分发说明

本文说明如何在 macOS 14 或更新版本上生成可携带的 Apple Silicon 发行包。当前仓库的发行目标是 `arm64`；它不承诺 Intel 或 Universal 二进制。

## 生成本地发行包

先确认 Swift、Xcode 命令行工具、用于当前 Swift Package 编译的 Homebrew zstd（`brew install zstd`）和网络可用。运行发行包的用户不需要安装 Homebrew。打包脚本会调用
`scripts/build-zstd.sh`，从官方 zstd `v1.5.7` 源码下载一次并校验固定
SHA-256，再以 `arm64`、`MACOSX_DEPLOYMENT_TARGET=14.0` 编译。源码和编译
结果缓存于：

```text
.build/dependencies/zstd/1.5.7-macos14-arm64/
```

然后执行：

```bash
make package
```

脚本会完成以下步骤：

1. 构建 release 可执行文件和 SwiftPM 资源 bundle（若未通过
   `RELEASE_BIN_PATH` 指定已有 build）。
2. 创建 `.build/WeChatHUD.app`，复制 `Info.plist` 和资源。
3. 将 zstd 动态库复制到 `Contents/Frameworks`。
4. 将主程序的 zstd load command 改为 `@executable_path/../Frameworks/libzstd.1.dylib`，并同步设置 dylib 的 install name。
5. 把官方 zstd 的 `LICENSE` 和来源说明放入 `Contents/Resources/THIRD_PARTY_LICENSES`。
6. 先签名嵌套 dylib，再签名 app，并执行严格签名校验和 `bundle-check`；直接运行包内程序检查动态库和内置提示词，不读取账号或请求 AI。
7. 生成 app、zip 和 SHA-256 清单：

```text
.build/WeChatHUD.app
.build/distribution/WeChatHUD-<version>-macOS14-arm64.zip
.build/distribution/WeChatHUD-<version>-macOS14-arm64.zip.sha256
```

脚本会用 `vtool` 检查主程序和 zstd dylib 都是 arm64 且
`minos <= 14.0`，不允许 `/opt/homebrew` 或 `/usr/local/opt/zstd`
出现在打包后的 Mach-O load commands 中。它不会访问微信数据库，不会
读取 Codex 或其他 API 凭据；使用 Developer ID 时，签名时间戳会请求
Apple 服务。

本机验证默认使用仓库约定的 `WeChatHUD-DevCert` 身份。没有该本地身份时，显式使用 ad hoc 签名：

```bash
make app SIGN_IDENTITY=-
codesign --verify --deep --strict --verbose=2 .build/WeChatHUD.app
otool -L .build/WeChatHUD.app/Contents/MacOS/WeChatHUD
open .build/WeChatHUD.app
```

如果只需要复用已有的 release binary、避免重新编译主程序，可以显式传入：

```bash
RELEASE_BIN_PATH=".build/arm64-apple-macosx/release" SIGN_IDENTITY="WeChatHUD-DevCert" scripts/package-app.sh --archive
```

上面的变量用于复用已经构建的 release binary，避免为了重新打包而再次编译主程序。

只有在已有兼容依赖需要人工复核时，才通过以下变量指定一个已经是 arm64 且
`minos <= 14.0` 的 dylib 及其许可证：

```bash
ZSTD_DYLIB="/path/to/libzstd.1.dylib" \
ZSTD_LICENSE="/path/to/LICENSE" \
RELEASE_BIN_PATH=".build/arm64-apple-macosx/release" \
scripts/package-app.sh --archive
```

脚本不会因为指定了外部 dylib 而跳过架构和部署目标校验。

## Developer ID 签名

外部分发必须使用 Developer ID Application 身份。签名身份通过 `SIGN_IDENTITY` 覆盖：

```bash
make package SIGN_IDENTITY="Developer ID Application: Example, Inc."
```

如证书保存在非默认钥匙串，可额外设置 `SIGN_KEYCHAIN=/path/to/keychain-db`，无需更改系统钥匙串搜索列表。

正式签名应由发布者在自己的钥匙串中完成。只有身份以
`Developer ID Application:` 开头时，打包脚本才在嵌套依赖和 app 两层
启用 hardened runtime 与时间戳。仓库的本地 `WeChatHUD-DevCert` 身份
没有 Team ID 时会使用普通签名，不启用 runtime 或 timestamp，以避免
dyld 拒绝混合签名的嵌套 dylib。签名完成后应核对：

```bash
codesign -dv --verbose=4 .build/WeChatHUD.app
codesign --verify --deep --strict --verbose=2 .build/WeChatHUD.app
spctl --assess --type execute --verbose=4 .build/WeChatHUD.app
```

`spctl` 在公证前可能拒绝，这是预期的 Gatekeeper 状态；它不能替代公证后的验证。

## 公证和装订

`make notarize` 是一个显式的人工门槛。它要求同时提供 Developer ID 身份、已存在的发行 zip 和本地 `notarytool` 钥匙串 profile，只打印待执行命令，绝不自动向 Apple 上传：

```bash
make notarize \
  SIGN_IDENTITY="Developer ID Application: Example, Inc." \
  NOTARY_PROFILE="wechathud-notary"
```

审阅命令和目标后，由发布者手动执行输出的命令：

```bash
xcrun notarytool submit ".build/distribution/WeChatHUD-<version>-macOS14-arm64.zip" \
  --keychain-profile "wechathud-notary" --wait
xcrun stapler staple .build/WeChatHUD.app
spctl --assess --type execute --verbose=4 .build/WeChatHUD.app
make archive-notarized
```

最后一步校验装订和 Gatekeeper，再重新生成包含公证票据的 zip 和 SHA-256 清单，不会重新构建或签名。

不要把 Apple ID、App Store Connect API key、notary profile 内容或任何 API key 写入仓库、脚本、日志或发行包。公证 profile 只保存在发布机的钥匙串中。

## 发布前检查

- `make test` 通过，并记录跳过项和任何 live 服务限制。
- 在干净的 macOS 14 arm64 机器上解压 zip，确认 app 能启动。
- `vtool -show-build` 显示主程序和嵌套 zstd 的 `minos <= 14.0`。
- `otool -L` 只显示系统库和 `@executable_path/../Frameworks/libzstd.1.dylib`，不含开发机路径。
- `codesign --verify`、`spctl` 和公证状态均符合当前签名阶段。
- SHA-256 清单与实际 zip 一致。
- `Contents/Resources/THIRD_PARTY_LICENSES/zstd-LICENSE.txt` 随包存在。
- 首次运行按[使用指南](user-guide.md)配置微信目录、匹配的解密密钥和辅助功能权限。
- 发行说明明确标注 arm64、macOS 14+、数据处理边界、自动托管默认状态及微信版本兼容限制。
