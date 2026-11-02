#!/bin/bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDOVER="$PROJECT_DIR/docs/HANDOVER_SIGN_INSTALL_IPAD.md"
PBXPROJ="$PROJECT_DIR/ATMusic.xcodeproj/project.pbxproj"
PROJECT_YML="$PROJECT_DIR/project.yml"
LOCK_DIR="/tmp/atmusic-ipad-install.lock"
CERT_DIR="$PROJECT_DIR/ipad_cert"
CERT_ZIP="$PROJECT_DIR/ipad证书_00008122-000A21A002DA801C 2.zip"

BUILD_DIR=""
LOG_FILE=""
LOCK_ACQUIRED=0

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\n❌ %s\n' "$*" >&2; exit 1; }
warn() { printf '\n⚠️  %s\n' "$*"; }

cleanup() {
  if [[ -n "${BUILD_DIR:-}" && -d "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR" 2>/dev/null || true
  fi
  if [[ "$LOCK_ACQUIRED" == "1" ]]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

acquire_lock() {
  local holder=""
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_ACQUIRED=1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    return
  fi
  holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
    fail "已有 ATMusic iPad 安装任务正在运行（PID $holder），请等它完成。"
  fi
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR" || fail "无法创建安装锁：$LOCK_DIR"
  LOCK_ACQUIRED=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

read_cfg() {
  local key="$1"
  if [[ -f "$HANDOVER" ]]; then
    sed -n "s/^${key}=\"\([^\"]*\)\"/\\1/p" "$HANDOVER" | head -1
  fi
}

persist_build_number() {
  local old="$1" new="$2"
  perl -0pi -e "s/CURRENT_PROJECT_VERSION = ${old};/CURRENT_PROJECT_VERSION = ${new};/g" "$PBXPROJ"
  if [[ -f "$PROJECT_YML" ]]; then
    perl -0pi -e "s/CURRENT_PROJECT_VERSION: \"${old}\"/CURRENT_PROJECT_VERSION: \"${new}\"/g" "$PROJECT_YML"
  fi
  grep -q "CURRENT_PROJECT_VERSION = ${new};" "$PBXPROJ" || fail "安装成功，但工程 Build 号写回失败"
  if [[ -f "$PROJECT_YML" ]]; then
    grep -q "CURRENT_PROJECT_VERSION: \"${new}\"" "$PROJECT_YML" || fail "安装成功，但 project.yml Build 号写回失败"
  fi
}

# 1. 自动寻找可用的 Xcode 开发环境与命令行工具
ensure_developer_tools() {
  if ! xcodebuild -version >/dev/null 2>&1 || ! xcrun devicectl --version >/dev/null 2>&1; then
    for xcode_cand in "/Applications/Xcode.app/Contents/Developer" "/Applications/Xcode-beta.app/Contents/Developer"; do
      if [[ -d "$xcode_cand" ]]; then
        export DEVELOPER_DIR="$xcode_cand"
        break
      fi
    done
  fi
}

# 2. 自动转换并安装 iPad 证书与描述文件
setup_certificates() {
  say "检查并配置 iPad 证书与描述文件"
  mkdir -p "$CERT_DIR"

  if [[ ! -f "$CERT_DIR/证书文件.p12" || ! -f "$CERT_DIR/描述文件.mobileprovision" ]]; then
    if [[ -f "$CERT_ZIP" ]]; then
      say "正在解压 iPad 证书压缩包..."
      python3 -c "
import zipfile, os
zf = zipfile.ZipFile('$CERT_ZIP')
zf.extractall('$CERT_DIR')
" || fail "无法解压 iPad 证书包：$CERT_ZIP"
    else
      fail "找不到 iPad 证书包：$CERT_ZIP"
    fi
  fi

  local p12_file="$CERT_DIR/证书文件.p12"
  local profile_file="$CERT_DIR/描述文件.mobileprovision"
  local p12_pwd="1"
  if [[ -f "$CERT_DIR/密码.txt" ]]; then
    local read_pwd
    read_pwd="$(grep -oE '[0-9a-zA-Z]+$' "$CERT_DIR/密码.txt" || true)"
    [[ -n "$read_pwd" ]] && p12_pwd="$read_pwd"
  fi

  # 安装描述文件到 Xcode Provisioning Profiles 目录
  local target_profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  mkdir -p "$target_profiles_dir"
  cp -f "$profile_file" "$target_profiles_dir/${PROFILE_UUID}.mobileprovision"
  cp -f "$profile_file" "$CERT_DIR/${PROFILE_UUID}.mobileprovision" 2>/dev/null || true
  printf '✅ 描述文件已配置：%s.mobileprovision\n' "$PROFILE_UUID"

  # 转换 p12 为 macOS 钥匙串兼容格式（TripleDES + SHA1 MAC）
  local macos_p12="$CERT_DIR/证书文件_macos.p12"
  if [[ ! -f "$macos_p12" || $(stat -f%z "$macos_p12" 2>/dev/null || stat -c%s "$macos_p12" 2>/dev/null || echo 0) -lt 1000 ]]; then
    say "转换证书为 macOS 原生钥匙串格式..."
    openssl pkcs12 -in "$p12_file" -nodes -passin "pass:$p12_pwd" -out "/tmp/atmusic_cert_key.pem" 2>/dev/null && \
    openssl pkcs12 -export -in "/tmp/atmusic_cert_key.pem" -out "$macos_p12" -passout "pass:$p12_pwd" -descert -name "iPhone Distribution: Patricia Baldwin (M8CVQK8GFR)" 2>/dev/null && \
    rm -f "/tmp/atmusic_cert_key.pem" || true
  fi

  if [[ -f "$macos_p12" ]]; then
    p12_file="$macos_p12"
    cp -f "$macos_p12" "$CERT_DIR/证书文件.p12" 2>/dev/null || true
  fi

  # 检查钥匙串中是否已有该证书身份
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$TEAM_ID"; then
    say "导入 iPad 签名证书到钥匙串..."
    local user_kc="$HOME/Library/Keychains/login.keychain-db"
    [[ ! -f "$user_kc" ]] && user_kc="$HOME/Library/Keychains/login.keychain"

    if [[ -f "$user_kc" ]]; then
      security import "$p12_file" -k "$user_kc" -P "$p12_pwd" -T /usr/bin/codesign -T /usr/bin/security -A 2>&1 || true
    else
      security import "$p12_file" -P "$p12_pwd" -T /usr/bin/codesign -T /usr/bin/security -A 2>&1 || true
    fi
  fi

  # 确认证书是否成功就绪
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$TEAM_ID"; then
    local matched_id
    matched_id="$(security find-identity -v -p codesigning 2>/dev/null | grep "$TEAM_ID" | head -1 | awk -F'"' '{print $2}' || true)"
    printf '✅ 签名证书就绪：%s\n' "${matched_id:-Team ID $TEAM_ID}"
  else
    warn "未能在钥匙串中自动导入证书（可能由于钥匙串权限保护）。"
    say "正在为您调起钥匙串访问，请在弹出的导入窗口中输入密码 1..."
    open "$p12_file"
    printf '请在钥匙串弹窗中输入密码 1 并点击确定，完成后按回车键继续...\n'
    read -r -p "" </dev/tty || true
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$TEAM_ID"; then
      fail "未能检测到可用签名证书（Team ID: $TEAM_ID）。请确认已导入钥匙串并授权。"
    fi
  fi
}

# 3. 智能定位 iPad 设备标识
resolve_target_device() {
  local target_udid="$1"
  say "检查 iPad 连接状态 (UDID: $target_udid)"

  local devices_json="/tmp/atmusic-devicectl-devices.json"
  rm -f "$devices_json"

  local resolved_id=""
  if xcrun devicectl list devices --json-output "$devices_json" 2>/dev/null && [[ -f "$devices_json" ]]; then
    resolved_id="$(python3 -c "
import json, sys
target_udid = '$target_udid'.strip().lower()
try:
    with open('$devices_json') as f:
        data = json.load(f)
    devices = data.get('result', {}).get('devices', [])
    for d in devices:
        hw_udid = d.get('hardwareProperties', {}).get('udid', '').lower()
        if hw_udid == target_udid:
            print(d.get('identifier', ''))
            sys.exit(0)
    for d in devices:
        ident = d.get('identifier', '').lower()
        if ident == target_udid:
            print(d.get('identifier', ''))
            sys.exit(0)
    ipads = [d for d in devices if 'ipad' in d.get('hardwareProperties', {}).get('deviceType', '').lower() or 'ipad' in d.get('deviceProperties', {}).get('name', '').lower()]
    connected_ipads = [d for d in ipads if d.get('connectionProperties', {}).get('tunnelState') == 'connected']
    if len(connected_ipads) == 1:
        print(connected_ipads[0].get('identifier', ''))
        sys.exit(0)
except Exception:
    pass
print('')
")"
  fi

  if [[ -z "$resolved_id" ]]; then
    if xcrun devicectl list devices 2>/dev/null | grep -iF "$target_udid" | grep -q 'connected'; then
      resolved_id="$target_udid"
    fi
  fi

  if [[ -z "$resolved_id" ]]; then
    # 尝试匹配列表中唯一的 connected iPad
    resolved_id="$(xcrun devicectl list devices 2>/dev/null | grep -i 'iPad' | grep -i 'connected' | head -1 | awk '{print $3}' || true)"
  fi

  if [[ -z "$resolved_id" ]]; then
    printf '\n'
    warn "当前已连接设备列表："
    xcrun devicectl list devices 2>&1 || true
    fail "未找到匹配 UDID: $target_udid 的已连接 iPad。请确保 iPad 已通过数据线或同一 Wi-Fi 连接，并解锁信任此电脑。"
  fi

  printf '✅ 识别到目标 iPad 设备 ID：%s\n' "$resolved_id"
  TARGET_DEVICE_ID="$resolved_id"
}

# 4. 从未签名 IPA 重签名快速安装
resign_and_install_ipa() {
  local ipa_file="$1"
  local target_device="$2"
  say "使用最新无签名 IPA 进行重签名并安装：$(basename "$ipa_file")"

  local temp_dir
  temp_dir="$(mktemp -d "/tmp/atmusic-ipad-resign-XXXXXX")"
  unzip -q "$ipa_file" -d "$temp_dir" || fail "解压 IPA 失败"

  local app_dir
  app_dir="$(find "$temp_dir/Payload" -name "*.app" -type d | head -1)"
  [[ -d "$app_dir" ]] || fail "IPA 中未发现 Payload/*.app"

  # 替换描述文件与 Bundle ID
  cp -f "$CERT_DIR/描述文件.mobileprovision" "$app_dir/embedded.mobileprovision"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$app_dir/Info.plist"

  # 提取 entitlements
  local ent_plist="$temp_dir/entitlements.plist"
  python3 -c "
import plistlib, re
with open('$CERT_DIR/描述文件.mobileprovision', 'rb') as f:
    data = f.read()
m = re.search(rb'<\?xml.*?</plist>', data, re.DOTALL)
if m:
    plist = plistlib.loads(m.group(0))
    ent = plist.get('Entitlements', {})
    with open('$ent_plist', 'wb') as f_out:
        plistlib.dump(ent, f_out)
" || fail "提取 Entitlements 失败"

  rm -rf "$app_dir/_CodeSignature"

  local sign_identity
  sign_identity="$(security find-identity -v -p codesigning 2>/dev/null | grep "$TEAM_ID" | head -1 | awk '{print $2}' || true)"
  if [[ -z "$sign_identity" ]]; then
    sign_identity="212753819C55FC0CFD32B76EC81C6F58DBC7CA1A"
  fi

  say "对应用执行重签名 (Identity: $sign_identity)..."
  if [[ -d "$app_dir/Frameworks" ]]; then
    find "$app_dir/Frameworks" -type f \( -name "*.dylib" -o -perm +111 \) -exec codesign --force --sign "$sign_identity" --timestamp=none {} + 2>/dev/null || true
  fi

  codesign --force --sign "$sign_identity" --entitlements "$ent_plist" --generate-entitlement-der --timestamp=none "$app_dir" 2>/dev/null || \
  codesign --force --sign "$sign_identity" --entitlements "$ent_plist" --timestamp=none "$app_dir"

  codesign --verify --deep --strict --verbose=2 "$app_dir"

  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Info.plist" 2>/dev/null || echo "1.8.8")"
  local build
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_dir/Info.plist" 2>/dev/null || echo "41")"
  printf '✅ 签名有效：AT Music %s (Build %s)\n' "$version" "$build"

  say "正在安装应用到 iPad ($target_device)..."
  xcrun devicectl device install app --device "$target_device" "$app_dir"
  rm -rf "$temp_dir"
  printf '✅ 安装成功完成！\n'
}

# --- 主执行流程 ---

acquire_lock
ensure_developer_tools

[[ -f "$PBXPROJ" ]] || fail "找不到 Xcode 工程配置：$PBXPROJ"

DEVICE_ID="$(read_cfg DEVICE_ID)"
BUNDLE_ID="$(read_cfg BUNDLE_ID)"
TEAM_ID="$(read_cfg TEAM_ID)"
PROFILE_UUID="$(read_cfg PROFILE_UUID)"

DEVICE_ID="${DEVICE_ID:-00008122-000A21A002DA801C}"
BUNDLE_ID="${BUNDLE_ID:-app.cloud3381.hercules6682}"
TEAM_ID="${TEAM_ID:-M8CVQK8GFR}"
PROFILE_UUID="${PROFILE_UUID:-f59b3c24-e537-4cd8-acd8-87834aa649c1}"

setup_certificates

TARGET_DEVICE_ID=""
resolve_target_device "$DEVICE_ID"

# 检查是否具备直接通过源码编译 iOS 真机的 SDK 组件
CAN_SOURCE_BUILD=1
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  CAN_SOURCE_BUILD=0
fi

LATEST_IPA="$(find "$PROJECT_DIR" -maxdepth 1 -name "AT-Music-*-unsigned*.ipa" | sort -V | tail -1)"

if [[ "$CAN_SOURCE_BUILD" == "0" && -n "$LATEST_IPA" && -f "$LATEST_IPA" ]]; then
  say "检测到 Xcode 未就绪本地真机编译 SDK 组件，自动启用【IPA 快速重签名安装通道】"
  printf '使用构建包：%s\n' "$(basename "$LATEST_IPA")"
  resign_and_install_ipa "$LATEST_IPA" "$TARGET_DEVICE_ID"
else
  OLD_BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([0-9]+);/\1/')"
  [[ "$OLD_BUILD" =~ ^[0-9]+$ ]] || OLD_BUILD="1"
  NEW_BUILD=$((OLD_BUILD + 1))
  BUILD_DIR="$(mktemp -d "/tmp/atmusic-ipad-build-${NEW_BUILD}-XXXXXX")"
  APP_PATH="$BUILD_DIR/Build/Products/Release-iphoneos/ATMusic.app"
  LOG_FILE="/tmp/atmusic-ipad-install-${NEW_BUILD}.log"
  rm -f "$LOG_FILE"

  printf '准备构建 iPad 版：Build %s -> %s\n' "$OLD_BUILD" "$NEW_BUILD"
  printf '日志路径：%s\n' "$LOG_FILE"

  say "Release 真机构建（使用 iPad 专属证书与 Profile）"
  set +e
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
    build 2>&1 | tee "$LOG_FILE"
  BUILD_RC=${PIPESTATUS[0]}
  set -e

  if [[ $BUILD_RC -ne 0 ]]; then
    warn "Xcode 直接源码构建未成功 (退出码 $BUILD_RC)"
    if [[ -n "$LATEST_IPA" && -f "$LATEST_IPA" ]]; then
      say "无缝切换为【IPA 快速重签名安装通道】..."
      resign_and_install_ipa "$LATEST_IPA" "$TARGET_DEVICE_ID"
    else
      fail "Xcode 构建失败且未找到可用的未签名 IPA；工程 Build 号仍为 $OLD_BUILD"
    fi
  else
    grep -q '\*\* BUILD SUCCEEDED \*\*' "$LOG_FILE" || fail "未检测到 BUILD SUCCEEDED"

    say "严格校验构建产物"
    [[ -d "$APP_PATH" ]] || fail "没有生成 ATMusic.app"
    [[ -f "$APP_PATH/Info.plist" ]] || fail "ATMusic.app 缺少 Info.plist"
    EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist")"
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Info.plist")"
    BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Info.plist")"
    BUILT_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
    [[ -n "$EXECUTABLE" ]] || fail "Info.plist 缺少 CFBundleExecutable"
    [[ -x "$APP_PATH/$EXECUTABLE" ]] || fail "主执行文件不存在或不可执行：$EXECUTABLE"
    [[ "$BUILT_BUILD" == "$NEW_BUILD" ]] || fail "产物 Build 不匹配：预期 $NEW_BUILD，实际 $BUILT_BUILD"
    [[ "$BUILT_BUNDLE" == "$BUNDLE_ID" ]] || fail "Bundle ID 不匹配：$BUILT_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    printf '✅ 构建有效：AT Music %s (%s)\n' "$VERSION" "$BUILT_BUILD"

    say "安装到 iPad"
    xcrun devicectl device install app --device "$TARGET_DEVICE_ID" "$APP_PATH"

    say "安装成功后写回工程 Build 号"
    persist_build_number "$OLD_BUILD" "$NEW_BUILD"
    printf '✅ 工程 Build 已提交：%s -> %s\n' "$OLD_BUILD" "$NEW_BUILD"
  fi
fi

say "尝试在 iPad 上自动启动"
set +e
LAUNCH_OUTPUT="$(xcrun devicectl device process launch --device "$TARGET_DEVICE_ID" --terminate-existing "$BUNDLE_ID" 2>&1)"
LAUNCH_CODE=$?
set -e
printf '%s\n' "$LAUNCH_OUTPUT"

if [[ $LAUNCH_CODE -eq 0 ]]; then
  printf '\n✅ iPad 安装并启动成功：AT Music (%s)\n' "$BUNDLE_ID"
elif printf '%s' "$LAUNCH_OUTPUT" | grep -qi 'Locked'; then
  printf '\n✅ iPad 安装成功：AT Music (%s)\n' "$BUNDLE_ID"
  printf 'ℹ️ iPad 当前锁屏，解锁后在桌面点击应用图标即可打开。\n'
else
  printf '\n✅ iPad 安装成功：AT Music (%s)\n' "$BUNDLE_ID"
  printf 'ℹ️ 若无法自动拉起，请在 iPad 主屏幕点击「AT Music」图标启动。\n'
fi
