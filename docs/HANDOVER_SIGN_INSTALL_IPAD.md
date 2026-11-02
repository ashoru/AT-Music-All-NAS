# AT Music iPad 签名与一键安装交接文档

## 1. 文档目的

记录 AT Music 安装至 iPad（UDID: `00008122-000A21A002DA801C`）的完整签名构建与一键安装配置。

本流程基于 `ipad证书_00008122-000A21A002DA801C 2.zip` 提供的专用 iPad 签名证书与描述文件进行配置。

## 2. iPad 项目与证书设备信息

```sh
PROJECT_DIR="/Users/tangfengjing/gemini/app_music/AT-Music-main"
BUILD_DIR="/tmp/atmusic-ipad-build"
DEVICE_ID="00008122-000A21A002DA801C"
BUNDLE_ID="app.cloud3381.hercules6682"
TEAM_ID="M8CVQK8GFR"
PROFILE_UUID="f59b3c24-e537-4cd8-acd8-87834aa649c1"
```

当前 iPad 签名证书：
```text
证书名称: iPhone Distribution: Patricia Baldwin (M8CVQK8GFR)
Team ID: M8CVQK8GFR
Team Name: Patricia Baldwin
证书密码: 1
描述文件名称: 00008122-000A21A002DA801CXOYU4E
描述文件 UUID: f59b3c24-e537-4cd8-acd8-87834aa649c1
绑定 Bundle ID: app.cloud3381.hercules6682
绑定设备 UDID: 00008122-000A21A002DA801C
有效期至: 2027-09-22
```

## 3. 前置自动导入（脚本已内置）

1. **证书导入**：
   `证书文件.p12`（密码：`1`）自动导入到当前用户的钥匙串（login keychain），并授权 `codesign` 使用。
2. **描述文件安装**：
   `描述文件.mobileprovision` 自动复制至：
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/f59b3c24-e537-4cd8-acd8-87834aa649c1.mobileprovision`

## 4. 核心构建命令

构建命令中动态指定该描述文件绑定的 Bundle ID，不影响原有工程默认配置：

```sh
xcodebuild \
  -project "$PROJECT_DIR/ATMusic.xcodeproj" \
  -scheme ATMusic \
  -sdk iphoneos \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CURRENT_PROJECT_VERSION="$NEW_BUILD" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='iPhone Distribution' \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID" \
  build
```

## 5. 校验与安装

```sh
# 1. 签名深度校验
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# 2. 安装到 iPad
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

# 3. 启动应用
xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID"
```

## 6. 注意事项

1. **锁屏限制**：安装过程中如果 iPad 锁屏，`devicectl process launch` 可能返回 `Locked`，解锁 iPad 后即可直接在屏幕上点击运行。
2. **首次安装信任**：若首次使用该企业/开发者证书，在 iPad 上进入「设置」->「通用」->「VPN 与设备管理」中信任「Patricia Baldwin」证书。
