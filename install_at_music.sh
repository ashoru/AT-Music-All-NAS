#!/bin/bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDOVER="$PROJECT_DIR/docs/HANDOVER_SIGN_INSTALL.md"
PBXPROJ="$PROJECT_DIR/ATMusic.xcodeproj/project.pbxproj"
PROJECT_YML="$PROJECT_DIR/project.yml"
LOCK_DIR="/tmp/atmusic-install.lock"
BUILD_DIR=""
LOG_FILE=""
LOCK_ACQUIRED=0

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

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
    fail "已有 ATMusic 安装任务正在运行（PID $holder），请等它完成。"
  fi
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR" || fail "无法创建安装锁：$LOCK_DIR"
  LOCK_ACQUIRED=1
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

read_cfg() {
  local key="$1"
  sed -n "s/^${key}=\"\([^\"]*\)\"/\\1/p" "$HANDOVER" | head -1
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

acquire_lock
[[ -f "$HANDOVER" ]] || fail "找不到交接文档：$HANDOVER"
[[ -f "$PBXPROJ" ]] || fail "找不到 Xcode 工程配置"

DEVICE_ID="$(read_cfg DEVICE_ID)"
BUNDLE_ID="$(read_cfg BUNDLE_ID)"
TEAM_ID="$(read_cfg TEAM_ID)"
PROFILE_UUID="$(read_cfg PROFILE_UUID)"
[[ -n "$DEVICE_ID" ]] || fail "缺少 DEVICE_ID"
[[ -n "$BUNDLE_ID" ]] || fail "缺少 BUNDLE_ID"
[[ -n "$TEAM_ID" ]] || fail "缺少 TEAM_ID"
[[ -n "$PROFILE_UUID" ]] || fail "缺少 PROFILE_UUID"

say "检查 iPhone 连接状态"
xcrun devicectl list devices | grep -F "$DEVICE_ID" | grep -q 'connected' || fail "目标 iPhone 未连接"

OLD_BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([0-9]+);/\1/')"
[[ "$OLD_BUILD" =~ ^[0-9]+$ ]] || fail "无法读取当前 Build 号"
NEW_BUILD=$((OLD_BUILD + 1))
BUILD_DIR="$(mktemp -d "/tmp/atmusic-build-${NEW_BUILD}-XXXXXX")"
APP_PATH="$BUILD_DIR/Build/Products/Release-iphoneos/ATMusic.app"
LOG_FILE="/tmp/atmusic-install-${NEW_BUILD}.log"
rm -f "$LOG_FILE"
printf '准备构建：Build %s -> %s（工程文件暂不修改）\n' "$OLD_BUILD" "$NEW_BUILD"
printf '日志：%s\n' "$LOG_FILE"

say "Release 真机构建（独立临时目录）"
set +e
xcodebuild \
  -project "$PROJECT_DIR/ATMusic.xcodeproj" \
  -scheme ATMusic \
  -sdk iphoneos \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  CURRENT_PROJECT_VERSION="$NEW_BUILD" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='iPhone Distribution' \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID" \
  build 2>&1 | tee "$LOG_FILE"
BUILD_RC=${PIPESTATUS[0]}
set -e
if [[ $BUILD_RC -ne 0 ]]; then
  printf '\n--- 编译错误摘要 ---\n' >&2
  grep -E 'error:|fatal error:|BUILD FAILED|BUILD INTERRUPTED' "$LOG_FILE" | tail -40 >&2 || true
  fail "Xcode 构建失败；工程 Build 号仍为 $OLD_BUILD"
fi
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

say "安装到 iPhone"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

say "安装成功后写回工程 Build 号"
persist_build_number "$OLD_BUILD" "$NEW_BUILD"
printf '✅ 工程 Build 已提交：%s -> %s\n' "$OLD_BUILD" "$NEW_BUILD"

say "尝试自动启动"
set +e
LAUNCH_OUTPUT="$(xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" 2>&1)"
LAUNCH_CODE=$?
set -e
printf '%s\n' "$LAUNCH_OUTPUT"

if [[ $LAUNCH_CODE -eq 0 ]]; then
  printf '\n✅ 安装并启动成功：AT Music %s (%s)\n' "$VERSION" "$BUILT_BUILD"
elif printf '%s' "$LAUNCH_OUTPUT" | grep -qi 'Locked'; then
  printf '\n✅ 安装成功：AT Music %s (%s)\n' "$VERSION" "$BUILT_BUILD"
  printf 'ℹ️ iPhone 锁屏，解锁后手动打开即可。\n'
else
  printf '\n✅ 安装成功：AT Music %s (%s)\n' "$VERSION" "$BUILT_BUILD"
  printf '⚠️ 自动启动失败，但安装和 Build 号提交都已完成。\n'
fi
