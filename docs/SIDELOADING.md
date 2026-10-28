# 安装 Release IPA

GitHub Release 提供 iPhone Release IPA，接收方使用自己的 Apple 账号，通过支持重签的侧载工具安装。

1. 下载 Release 中的 `CivitViewer-0.3.0-build58-sideload.ipa`。
2. 在 Mac 或 Windows 上的侧载工具中选择 IPA，并使用自己的 Apple 账号完成签名与安装。账号密码、验证码仅在你选择的工具或 Apple 官方验证界面处理。
3. 如 iPhone 要求启用开发者模式或信任开发者，请按手机本机提示处理；随后打开 Civit Viewer，用自己的 Civitai 账号登录。

包内不含个人设备描述文件、个人证书签名或个人签名权限。包中的本地校验签名需要由侧载工具替换。下载链接用于取得文件，不能直接点击网页链接完成 iOS 安装。

最低 iOS 17，仅包含 iPhone 真机 arm64 代码。安装有效期和刷新方式取决于接收方实际使用的 Apple 账号、描述文件和侧载工具；此包不提供统一的安装有效期。原始个人开发签名包不会上传到公开 Release。

## 从源码生成

在仓库根目录使用完整 Xcode 构建；不会登录 Apple 账号或申请描述文件：

```sh
xcodebuild -project CivitViewer.xcodeproj -scheme CivitViewer \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/ReleaseIPA58 -jobs 2 \
  CLANG_ENABLE_CODE_COVERAGE=NO ENABLE_CODE_COVERAGE=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= build

python3 scripts/package-release-ipa.py \
  --app build/ReleaseIPA58/Build/Products/Release-iphoneos/CivitViewer.app \
  --output build/ipa58/CivitViewer-0.3.0-build58-sideload.ipa \
  --report build/ipa58/package-verification.json
```

脚本只修改临时副本，移除描述文件与旧签名元数据，用无个人身份的本地校验签名检查完整性，再验证 IPA 的 CRC 和逐文件哈希。它不会修改输入 `.app`，也不会替接收方取得安装授权。已存在的输出不会被覆盖。

Release 保留 FFmpeg LGPL 许可证；固定版本源代码、公开签名 key 和构建配置在 `Vendor/FFmpeg/`，包装代码在 `Vendor/CivitMediaEngine/`。
