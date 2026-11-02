# AT Music 签名安装交接文档

## 1. 文档目的

记录当前 AT Music iOS 版本从源码构建、手动签名、校验、安装到真机启动的完整流程，方便后续继续开发或交接给其他人使用。

本流程已在 iPhone Tang 真机上验证成功，当前验证版本为 Build 31，营销版本为 1.8.1。

### 2026-09-25 Build 31 验证记录

- `CFBundleShortVersionString = 1.8.1`，`CFBundleVersion = 31`。
- `CFBundleExecutable = ATMusic`，主执行文件存在且可执行。
- 最终 Release 构建无 warning，`codesign --verify --deep --strict` 通过。
- `devicectl device install app` 覆盖安装成功；`devicectl device process launch --terminate-existing` 启动成功。
- 启动后再次查询真机进程，Build 31 对应的 ATMusic 进程持续存活。
- 一键脚本现使用唯一临时 DerivedData 目录；工程 Build 号只在“构建 + 验签 + 安装”全部成功后写回。失败时工程 Build 号保持不变。
- 构建日志保存为 `/tmp/atmusic-install-<build>.log`；失败会打印最后的编译错误摘要。

### 2026-09-25 Build 29 验证记录

- `CFBundleShortVersionString = 1.8.1`，`CFBundleVersion = 29`。
- `CFBundleExecutable = ATMusic`，主执行文件存在并可执行。
- `codesign --verify --deep --strict` 通过。
- Build 29 的历史真机验证记录来自旧 Bundle ID；当前公开工程使用新的 AT Music Bundle ID。
- `devicectl device process launch` 启动成功，安装容器对应的 ATMusic 进程持续存活。
- 一键安装脚本增加 `/tmp/atmusic-install.lock` 单实例锁；并发启动时第二个任务会直接退出，不再清理或覆盖正在构建的产物。

## 2. 项目与设备信息

以下信息是本机当前配置。Team ID、描述文件 UUID 和设备 ID 都可能随机器、证书或设备变化，不能写死到代码或提交到仓库。

```sh
PROJECT_DIR="/Users/tangfengjing/gemini/app_music/AT-Music-main"
BUILD_DIR="/tmp/atmusic-build-device"
DEVICE_ID="<YOUR_DEVICE_ID>"
BUNDLE_ID="com.atmusic.player"
TEAM_ID="<YOUR_TEAM_ID>"
PROFILE_UUID="<YOUR_PROFILE_UUID>"
```

当前签名证书：

```text
iPhone Distribution: <YOUR_CERTIFICATE> (<YOUR_TEAM_ID>)
SHA-1: <YOUR_CERTIFICATE_SHA1>
```

## 3. 前置条件

- Mac 已安装 Xcode 和对应的 iOS SDK。
- Apple Distribution/Development 证书已经安装到当前用户的钥匙串。
- 对应的 provisioning profile 已安装到：

  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`

- iPhone 已通过 USB 或可用的网络方式连接，并已信任这台 Mac。
- 如设备要求，打开开发者模式。
- 真机安装必须使用有效签名；模拟器可以关闭签名，但不能用模拟器构建产物安装到 iPhone。

不要把证书私钥、`.p12` 文件、描述文件副本、Apple 账号密码、NAS 密码或其他私密凭据提交到仓库。

## 4. 查找并检查描述文件

列出当前用户安装的描述文件：

```sh
find "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
  -type f -maxdepth 2 -print
```

解码目标描述文件：

```sh
PROFILE_PATH="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$PROFILE_UUID.mobileprovision"
security cms -D -i "$PROFILE_PATH" > /tmp/atmusic-profile.plist

/usr/libexec/PlistBuddy -c 'Print :UUID' /tmp/atmusic-profile.plist
/usr/libexec/PlistBuddy -c 'Print :Name' /tmp/atmusic-profile.plist
/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' /tmp/atmusic-profile.plist
/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' /tmp/atmusic-profile.plist
```

必须确认：

- Team ID 与签名证书一致。
- `application-identifier` 应与 `<YOUR_TEAM_ID>.com.atmusic.player` 匹配。
- 描述文件包含当前真机的 UDID。
- Bundle ID 与工程中的 Bundle Identifier 一致。

## 5. 构建并手动签名 Release 真机版本

```sh
cd "$PROJECT_DIR"

xcodebuild \
  -project ATMusic.xcodeproj \
  -scheme ATMusic \
  -sdk iphoneos \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='iPhone Distribution' \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID" \
  build
```

构建产物位置：

```sh
APP_PATH="$BUILD_DIR/Build/Products/Release-iphoneos/ATMusic.app"
```

使用 `PROVISIONING_PROFILE_SPECIFIER` 时，可以填写描述文件 UUID；如果工程或 Xcode 对名称有要求，也可以填写描述文件 Name，但 UUID 更容易避免同名冲突。

## 6. 构建后校验

先校验签名：

```sh
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
```

再检查版本号：

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist"
```

必要时检查实际签名信息：

```sh
codesign -dvv "$APP_PATH" 2>&1 | sed -n '1,20p'
```

确认输出中的 Team、Identifier 和签名证书符合预期后，再安装到手机。

## 7. 安装到 iPhone

先查看当前连接设备：

```sh
xcrun devicectl list devices
```

安装应用：

```sh
xcrun devicectl device install app \
  --device "$DEVICE_ID" \
  "$APP_PATH"
```

安装成功后启动：

```sh
xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  --terminate-existing \
  "$BUNDLE_ID"
```

如果只是替换测试版本，直接重新执行安装即可。应用数据通常会保留，但涉及卸载、Bundle ID 变化或数据模型迁移时，应先确认是否需要备份。

## 8. 锁屏与 iPhone 镜像注意事项

- `devicectl device install app` 在部分情况下可以在设备锁定时完成。
- `devicectl device process launch` 需要设备处于可用状态；如果手机锁定，可能报 `FBSOpenApplicationServiceErrorDomain error 1` 或 `Locked`。
- 进行 iPhone 镜像时，手机通常需要保持锁定且没有被其他操作占用；如果 Mac 提示“iPhone 使用中，请锁定 iPhone 以连接”，先结束手机上的交互并锁屏。
- 如果要启动刚安装的应用但收到 `Locked`，解锁一次手机后重新执行启动命令即可。

## 9. 常见问题处理

### Signing for ATMusic requires a development team

构建命令没有传入 Team 或工程当前签名配置不完整。重新执行第 5 节命令，并确认 `DEVELOPMENT_TEAM`、`CODE_SIGN_STYLE`、`CODE_SIGN_IDENTITY` 和 `PROVISIONING_PROFILE_SPECIFIER` 都存在。

### No profiles found

描述文件未安装、UUID 不对，或描述文件不包含当前 Bundle ID。重新执行第 4 节，找到正确 profile 后更新 `PROFILE_UUID`。

### Provisioning profile doesn't match

通常是 Team ID、Bundle ID、设备 UDID 或签名证书不匹配。逐项检查描述文件的 `application-identifier`、`application-groups`（如项目使用）以及设备是否已加入 profile。

### 安装成功但无法启动

优先检查：

1. 手机是否锁定。
2. Bundle ID 是否为 `com.atmusic.player`。
3. 设备是否仍显示为已连接。
4. 是否安装的是 `Release-iphoneos/ATMusic.app`，而不是模拟器产物。

### 模拟器构建

仅用于快速编译检查：

```sh
cd "$PROJECT_DIR"
xcodebuild \
  -project ATMusic.xcodeproj \
  -scheme ATMusic \
  -sdk iphonesimulator \
  -configuration Debug \
  -derivedDataPath /tmp/atmusic-build-simulator \
  CODE_SIGNING_ALLOWED=NO \
  build
```

模拟器产物不能通过 `devicectl` 安装到真机。

## 10. 每次交付前检查清单

- [ ] 源码已保存，更新日志已记录。
- [ ] Release 真机构建成功。
- [ ] `codesign --verify --deep --strict` 通过。
- [ ] 版本号和 Build 号正确。
- [ ] Bundle ID、Team ID、profile 和设备一致。
- [ ] 已安装到目标 iPhone。
- [ ] 已启动应用并完成关键页面冒烟测试。
- [ ] 聚合搜索、聚合首页和 NAS 相关功能未出现明显回归。
- [ ] 未把任何账号密码、证书私钥或描述文件秘密内容提交到仓库。

## 11. 本次验证记录

- 工程：AT Music
- 版本：1.8.1
- Build：26
- 结果：Release 真机构建、签名校验、安装均已成功。
- Launch: `devicectl` remote launch succeeded on iPhone Tang; the ATMusic process remained running after launch.
- 启动限制：设备锁定时启动会被系统拒绝，解锁后重新启动即可。
