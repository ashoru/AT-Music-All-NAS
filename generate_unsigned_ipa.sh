#!/bin/bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PBXPROJ="$PROJECT_DIR/ATMusic.xcodeproj/project.pbxproj"
PROJECT_YML="$PROJECT_DIR/project.yml"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\n❌ %s\n' "$*" >&2; exit 1; }

# 1. 检测开发工具
if ! xcodebuild -version >/dev/null 2>&1; then
  for xcode_cand in "/Applications/Xcode.app/Contents/Developer" "/Applications/Xcode-beta.app/Contents/Developer"; do
    if [[ -d "$xcode_cand" ]]; then
      export DEVELOPER_DIR="$xcode_cand"
      break
    fi
  done
fi

xcodebuild -version || fail "未找到可用的 Xcode 环境"

# 2. 读取版本与 Build 号
VERSION="$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([^;]+);/\1/' | tr -d ' ')"
OLD_BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ" | sed -E 's/.*= ([0-9]+);/\1/')"
[[ -n "$VERSION" ]] || VERSION="1.8.8"
[[ "$OLD_BUILD" =~ ^[0-9]+$ ]] || OLD_BUILD="41"
TARGET_BUILD="${TARGET_BUILD:-}"
if [[ -n "$TARGET_BUILD" ]]; then
  NEW_BUILD="$TARGET_BUILD"
else
  NEW_BUILD=$((OLD_BUILD + 1))
fi

say "准备构建 AT Music $VERSION (Build $OLD_BUILD -> $NEW_BUILD)"

BUILD_DIR="/tmp/atmusic-unsigned-build-${NEW_BUILD}"
LOG_FILE="/tmp/atmusic-build-${NEW_BUILD}.log"
rm -rf "$BUILD_DIR" "$LOG_FILE"
mkdir -p "$BUILD_DIR"

say "开始无签名 Release 编译..."
set +e
xcodebuild \
  -project "$PROJECT_DIR/ATMusic.xcodeproj" \
  -scheme ATMusic \
  -sdk iphoneos \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  CURRENT_PROJECT_VERSION="$NEW_BUILD" \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build 2>&1 | tee "$LOG_FILE"
BUILD_RC=${PIPESTATUS[0]}
set -e

if [[ $BUILD_RC -ne 0 ]]; then
  echo "--- 错误日志摘要 ---" >&2
  grep -E 'error:|fatal error:|BUILD FAILED' "$LOG_FILE" | tail -30 >&2 || true
  fail "Xcode 构建失败"
fi

APP_PATH="$BUILD_DIR/Build/Products/Release-iphoneos/ATMusic.app"
[[ -d "$APP_PATH" ]] || fail "未找到构建产物 ATMusic.app"

say "校验 App 产物..."
[[ -f "$APP_PATH/Info.plist" ]] || fail "缺少 Info.plist"

say "开始打包无签名 IPA..."
PAYLOAD_DIR="/tmp/atmusic_payload_${NEW_BUILD}"
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR/Payload"
cp -R "$APP_PATH" "$PAYLOAD_DIR/Payload/ATMusic.app"

IPA_FILENAME="AT-Music-${VERSION}-build${NEW_BUILD}-unsigned.ipa"
IPA_PATH="$PROJECT_DIR/$IPA_FILENAME"
LATEST_IPA="$PROJECT_DIR/AT-Music-unsigned.ipa"

rm -f "$IPA_PATH" "$LATEST_IPA"
cd "$PAYLOAD_DIR"
zip -qry "$IPA_PATH" Payload/
rm -rf "$PAYLOAD_DIR"
cp -f "$IPA_PATH" "$LATEST_IPA"

# 更新工程 build 号
if [[ "$OLD_BUILD" != "$NEW_BUILD" ]]; then
  perl -0pi -e "s/CURRENT_PROJECT_VERSION = ${OLD_BUILD};/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" "$PBXPROJ"
  if [[ -f "$PROJECT_YML" ]]; then
    perl -0pi -e "s/CURRENT_PROJECT_VERSION: \"${OLD_BUILD}\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/g" "$PROJECT_YML"
  fi
fi

# 同步到 iCloud（若脚本存在）
if [[ -f "$PROJECT_DIR/copy_unsigned_ipa_to_icloud.sh" ]]; then
  "$PROJECT_DIR/copy_unsigned_ipa_to_icloud.sh" "$IPA_PATH" 2>/dev/null || true
fi

say "✅ 无签名 IPA 生成成功！"
echo "文件路径: $IPA_PATH"
echo "通用链接: $LATEST_IPA"
ls -lh "$IPA_PATH"
